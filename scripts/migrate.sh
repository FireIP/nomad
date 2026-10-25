#!/usr/bin/env bash
# Guide Phase 7: live-migrate the VM to the other host, with pre-checks.
# Usage: migrate.sh <peer> [--dry-run] [--monitor[=1|2|3]]
#   peer       ssh target of the destination, e.g. you@laptop.local
#   --dry-run  run the pre-checks and print the command only
#   --monitor[=N]  every MONITOR_INTERVAL seconds (default 5) sample into $OUT_DIR/migration-<timestamp>.log:
#              1 (default) network bytes + `virsh domjobinfo` (3s timeout), local host only
#              2 + on BOTH hosts: I/O/memory pressure, busiest processes, QEMU threads
#              3 + image size, QEMU thread states/wchan, migration TCP sockets (to debug stalls)
# Run it on the host that currently runs the VM. Extra virsh migrate flags: MIGRATE_ARGS="...".
# --auto-converge is added by default (disable with NO_AUTO_CONVERGE=1).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEER=""
DRY_RUN=0
MONITOR=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --monitor) MONITOR=1 ;;
    --monitor=[123]) MONITOR="${a#--monitor=}" ;;
    -*) die "unknown option: $a" ;;
    *) [ -z "$PEER" ] || die "only one peer allowed"; PEER="$a" ;;
  esac
done
[ -n "$PEER" ] || die "usage: $0 <peer> [--dry-run] [--monitor[=1|2|3]]"
need_cmd virsh ssh xmllint

[ "$(vm_state "$DOMAIN")" = "running" ] || die "'$DOMAIN' is not running on this host"

log "Checking SSH to $PEER"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" true || die "SSH to $PEER failed or needs a prompt (guide Phase 1.2)"

log "Comparing hosts"
local_facts="$(facts)"
peer_facts="$(remote_facts "$PEER")"
problems=0
for k in qemu newest_q35 secmodels ovmf_code_size default_net_ip; do
  l="$(grep "^$k=" <<<"$local_facts")"; p="$(grep "^$k=" <<<"$peer_facts")"
  if [ "$l" != "$p" ]; then warn "mismatch: local '$l' vs peer '$p'"; problems=1; fi
done
grep -qx 'default_net_active=yes' <<<"$peer_facts" || { warn "peer's default network is not active"; problems=1; }

if [ "$(virsh dumpxml "$DOMAIN" | xmllint --xpath "boolean(//interface/rom[@bar='off'])" -)" != "true" ]; then
  warn "NIC option ROM is not disabled (<rom bar='off'/>); migration will fail if the hosts' ROM sizes differ (guide Phase 4)"
  problems=1
fi

if ssh -o BatchMode=yes "$PEER" "virsh --connect qemu:///system dominfo $DOMAIN" >/dev/null 2>&1; then
  warn "'$DOMAIN' is already defined on $PEER (stale definition); check it is shut off and intended to be overwritten"
fi
if ssh -o BatchMode=yes "$PEER" "test -e /var/lib/libvirt/images/$DOMAIN.qcow2"; then
  log "Disk file from an earlier migration exists on $PEER; it will be overwritten (expected)"
fi

[ "$problems" -eq 0 ] || die "pre-checks failed; fix the problems above (nothing was migrated)"

# By default QEMU connects to whatever the peer's hostname resolves to, IPv6 first. If the peer's
# firewall drops IPv6 on the migration ports each attempt waits for the TCP SYN timeout (~9 min in
# total). Pin the data connection to the peer's IPv4 address instead.
migrate_uri=()
if [[ " ${MIGRATE_ARGS:-} " != *" --migrateuri"* ]]; then
  peer_host="$(ssh -G "$PEER" | awk '$1=="hostname"{print $2; exit}')" || true
  peer_ip="$(getent ahostsv4 "${peer_host:-}" | awk 'NR==1{print $1}')" || true
  if [ -n "${peer_ip:-}" ]; then migrate_uri=(--migrateuri "tcp://$peer_ip")
  else warn "could not resolve an IPv4 address for $PEER; QEMU will choose the address itself"; fi
fi

# --auto-converge is on by default: a busy guest can dirty RAM as fast as the link sends it, so precopy
# never converges (453 s vs 221 s measured). It throttles guest vCPUs near the end. NO_AUTO_CONVERGE=1 disables it.
converge=()
if [ "${NO_AUTO_CONVERGE:-0}" != 1 ] && [[ " ${MIGRATE_ARGS:-} " != *" --auto-converge"* ]]; then
  converge=(--auto-converge)
fi

cmd=(virsh migrate --live --persistent --undefinesource --copy-storage-all --verbose "${converge[@]}" ${MIGRATE_ARGS:-}
     "${migrate_uri[@]}" "$DOMAIN" "qemu+ssh://$PEER/system")
log "${cmd[*]}"
[ "$DRY_RUN" -eq 1 ] && { log "Dry run, not migrating"; exit 0; }

if [ "$MONITOR" -ge 1 ]; then
  mon_log="$OUT_DIR/migration-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "# command: ${cmd[*]}"
    echo "# started: $(date -Is)"
    # -U: the image is in use by the running VM. Best effort only; never abort the migration over it.
    { qemu-img info -U "$(virsh domblklist "$DOMAIN" --details | awk '$2=="disk"{print $4; exit}')" 2>&1 \
        | grep -E 'virtual size|disk size|Permission|error' | sed 's/^/# /'; } || true
  } > "$mon_log"
  # Samples must not depend on libvirt answering: during a migration the domain job lock can be held
  # and `virsh domjobinfo` times out, so use /proc-based numbers on BOTH hosts (the idle windows
  # in a slow migration can be on either side) plus domjobinfo with a short timeout.
  probe() { # self-contained so it can be piped to the peer: probe <domain> <level 2|3>
    export LC_ALL=C
    local pid
    pid="$(cat "/run/libvirt/qemu/$1.pid" 2>/dev/null || pidof qemu-system-x86_64 | awk '{print $1}')" || true
    echo "[io pressure] $(head -n1 /proc/pressure/io 2>/dev/null)"
    echo "[mem pressure] $(head -n1 /proc/pressure/memory 2>/dev/null)"
    echo "[mem] $(awk '/MemAvailable|SwapFree|SwapTotal/{printf "%s%s ",$1,$2}' /proc/meminfo) swap-in/out kB/s: $(vmstat 1 2 | tail -n1 | awk '{print $7"/"$8}')"
    [ "$2" -ge 3 ] && echo "[image] $(stat -c 'size=%s allocated=%b*%B' "/var/lib/libvirt/images/$1.qcow2" 2>&1)"
    echo "[busiest processes]"
    top -b -n2 -d1 -w 120 2>&1 | awk '/^top -/{n++} n==2' | sed -n '7,11p'
    if [ -n "$pid" ]; then
      echo "[qemu threads]"
      top -H -b -n2 -d1 -w 120 -p "$pid" 2>&1 | awk '/^top -/{n++} n==2' | sed -n '7,10p'
      if [ "$2" -ge 3 ]; then
        echo "[qemu thread states: tid state wchan name]"
        ps -L -o tid=,stat=,wchan:28=,comm= -p "$pid" 2>&1 | awk '$2 !~ /^S/ || NR<=2' | head -8
        echo "[migration sockets]"
        ss -tin 2>&1 | grep -A1 -E ':(49[0-9]{3})\b' | head -8
      fi
    fi
  }
  iface="$(ip route show default | awk '{print $5; exit}')" || true
  (
    set +e
    while true; do
      {
        echo "=== $(date +%T)"
        echo "[net $iface] $(awk -v i="$iface:" '$1==i{print "rx_bytes="$2" tx_bytes="$10}' /proc/net/dev)"
        echo "[domjobinfo]"
        timeout 3 virsh domjobinfo "$DOMAIN" 2>&1 || echo "(no answer within 3s)"
        if [ "$MONITOR" -ge 2 ]; then
          echo "--- local ($(hostname))"
          probe "$DOMAIN" "$MONITOR"
          echo "--- peer ($PEER)"
          { declare -f probe; echo "probe $DOMAIN $MONITOR"; } | timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=3 "$PEER" bash -s 2>&1 \
            || echo "(peer probe failed or timed out)"
        fi
      } >> "$mon_log"
      sleep "${MONITOR_INTERVAL:-5}"
    done
  ) &
  mon_pid=$!
  trap 'kill "$mon_pid" 2>/dev/null || true' EXIT
  log "Monitor level $MONITOR: sampling into $mon_log (interface ${iface:-unknown})"
fi

rc=0
time "${cmd[@]}" || rc=$?

if [ "$MONITOR" -ge 1 ]; then
  kill "$mon_pid" 2>/dev/null || true
  # The domain is gone from this host after --undefinesource, so read the summary from the destination.
  {
    echo "--- completed job ($(date +%T), exit code $rc)"
    ssh -o BatchMode=yes "$PEER" "virsh --connect qemu:///system domjobinfo $DOMAIN --completed" 2>&1 || true
  } >> "$mon_log"
  log "Share $mon_log to analyse where the time went"
fi
exit "$rc"
