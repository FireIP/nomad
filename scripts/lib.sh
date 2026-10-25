#!/usr/bin/env bash
# Shared helpers for the nomad scripts. Source this file; don't run it.
# Everything assumes the system libvirt instance (qemu:///system), see guide Phase 1.4.

set -euo pipefail
export LC_ALL=C
export LIBVIRT_DEFAULT_URI=qemu:///system

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$REPO_DIR}"
DOMAIN="${DOMAIN:-nomad}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c (run scripts/01-install.sh)"
  done
}

pkg_mgr() {
  local m
  for m in apt-get dnf pacman; do
    if command -v "$m" >/dev/null 2>&1; then echo "$m"; return; fi
  done
  die "no supported package manager found (apt-get, dnf, pacman)"
}

vm_exists() { virsh dominfo "$1" >/dev/null 2>&1; }
vm_state()  { virsh domstate "$1" 2>/dev/null | tr -d '\n'; }

# Prints key=value lines describing everything that must match between hosts.
# Self-contained so it can be run remotely via remote_facts.
facts() {
  export LC_ALL=C
  local v="virsh --connect qemu:///system"
  echo "kvm_access=$([ -r /dev/kvm ] && [ -w /dev/kvm ] && echo ok || echo no)"
  echo "qemu=$(qemu-system-x86_64 --version 2>/dev/null | sed -n '1s/.*version \([0-9.]*\).*/\1/p')"
  echo "libvirt=$($v version 2>/dev/null | awk '/Using library/{print $4}')"
  echo "newest_q35=$($v capabilities 2>/dev/null | grep -o 'pc-q35-[0-9.]*' | sort -uV | tail -n1)"
  echo "secmodels=$($v capabilities 2>/dev/null | awk '/<secmodel>/{f=1} f&&/<model>/{gsub(/<\/?model>| /,""); printf "%s,", $0} /<\/secmodel>/{f=0}')"
  echo "ovmf_code_size=$(stat -L -c %s /usr/share/OVMF/OVMF_CODE_4M.ms.fd 2>/dev/null || echo missing)"
  echo "default_net_active=$($v net-info default 2>/dev/null | awk '/Active:/{print $2}')"
  echo "default_net_ip=$($v net-dumpxml default 2>/dev/null | grep -o "<ip address='[0-9.]*' netmask='[0-9.]*'" | head -n1)"
}

# Runs facts on the peer through bash, whatever the peer's login shell is (e.g. fish).
remote_facts() {
  { declare -f facts; echo facts; } | ssh -o BatchMode=yes "$1" bash -s
}

# Guest resize helpers (guide 8.1/8.2). Memory values are KiB.
cur_vcpus()    { virsh vcpucount "$1" --live --current; }
max_vcpus()    { virsh vcpucount "$1" --live --maximum; }
cur_mem_kib()  { virsh dommemstat "$1" | awk '$1=="actual"{print $2}'; }
max_mem_kib()  { virsh dominfo "$1" | awk '/^Max memory:/{print $3}'; }

# resize_guest <domain> <vcpus> <mem_kib> <timeout_s>: set both live and wait until the guest follows
# (the balloon only returns memory the guest frees, so shrinking can take minutes). Returns 1 on timeout.
resize_guest() {
  local dom="$1" vcpus="$2" mem="$3" timeout="$4" slack=262144 i
  [ "$(cur_vcpus "$dom")" = "$vcpus" ] || virsh setvcpus "$dom" "$vcpus" --live
  [ "$(cur_mem_kib "$dom")" -eq "$mem" ] || virsh setmem "$dom" "${mem}KiB" --live
  for ((i = 0; i < timeout; i += 2)); do
    [ "$(cur_vcpus "$dom")" = "$vcpus" ] && [ "$(cur_mem_kib "$dom")" -ge "$((mem - slack))" ] \
      && [ "$(cur_mem_kib "$dom")" -le "$((mem + slack))" ] && return 0
    sleep 2
  done
  warn "after ${timeout}s: $(cur_vcpus "$dom") vCPUs, $(($(cur_mem_kib "$dom") / 1024)) MiB (wanted $vcpus, $((mem / 1024)) MiB)"
  return 1
}

# Progress display for a long-running `virsh migrate` (used by migrate.sh --progress / nomad migrate).
fmt_dur()  { local s="$1"; if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60)); else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi; }
fmt_size() { awk -v b="$1" 'BEGIN{ if (b >= 1073741824) printf "%.1f GiB", b/1073741824; else printf "%.0f MiB", b/1048576 }'; }

# alert <message>: terminal bell, red message and a desktop notification when one is available.
alert() {
  printf '\a\n\033[1;31m!! %s\033[0m\n' "$*" >&2
  command -v notify-send >/dev/null 2>&1 && notify-send -u critical "nomad" "$*" >/dev/null 2>&1 || true
}

# Turns `virsh domjobinfo` text (stdin) into key=value lines in bytes.
parse_job() {
  awk '
    function b(v, u) { m["B"]=1; m["KiB"]=1024; m["MiB"]=1048576; m["GiB"]=1073741824; m["TiB"]=1099511627776; return v * m[u] }
    /^Job type:/          { running = ($3 == "Unbounded") }
    /^Data processed:/    { printf "data_done=%.0f\n", b($3, $4); have = 1 }
    /^Data remaining:/    { printf "data_left=%.0f\n", b($3, $4) }
    /^Memory remaining:/  { printf "mem_left=%.0f\n", b($3, $4) }
    /^File processed:/    { printf "file_done=%.0f\n", b($3, $4) }
    /^File remaining:/    { printf "file_left=%.0f\n", b($3, $4) }
    /^Iteration:/         { printf "iter=%d\n", $2 }
    END                   { printf "have=%d\n", (have && running) ? 1 : 0 }'
}

_progress_interrupt() {
  local a=n
  printf '\n'
  read -r -p "Abort the migration? [y/N] " a </dev/tty || true
  if [[ "$a" =~ ^[Yy] ]]; then virsh domjob-abort "$_PROG_DOM" || warn "could not abort the job"; fi
}

# run_with_progress <domain> <command...>: runs the (migrate) command in the background and shows phase,
# percentage, rate and ETA from `virsh domjobinfo` every 2 s. Alerts when no data moved for STALL_SECS (60).
# Ctrl-C asks whether to abort the migration instead of killing the display.
run_with_progress() {
  local dom="$1"; shift
  local out pid rc=0 stall="${STALL_SECS:-60}" start="$SECONDS" last_prog="$SECONDS" alerted=0 prev_done=-1
  local -a ht=() hb=()
  local info k v now rate eta phase line disk_pct i
  local have data_done data_left mem_left file_done file_left iter
  _PROG_DOM="$dom"
  out="$(mktemp)"
  "$@" >"$out" 2>&1 &
  pid=$!
  trap _progress_interrupt INT
  while kill -0 "$pid" 2>/dev/null; do
    have=0 data_done=0 data_left=0 mem_left=0 file_done=0 file_left=0 iter=0
    info="$(timeout 3 virsh domjobinfo "$dom" 2>/dev/null)" || info=""
    while IFS== read -r k v; do printf -v "$k" '%s' "$v"; done < <(parse_job <<<"$info")
    now="$SECONDS"
    if [ "$have" = 1 ]; then
      if [ "$data_done" -gt "$prev_done" ]; then
        last_prog="$now"; alerted=0; prev_done="$data_done"
        ht+=("$now"); hb+=("$data_done")
        while [ "${#ht[@]}" -gt 2 ] && [ "$((now - ht[0]))" -gt 30 ]; do ht=("${ht[@]:1}"); hb=("${hb[@]:1}"); done
      fi
      rate=0; eta="?"
      i=$((${#ht[@]} - 1))
      if [ "$((now - last_prog))" -lt 6 ] && [ "$i" -ge 1 ] && [ "${ht[i]}" -gt "${ht[0]}" ]; then
        rate=$(((hb[i] - hb[0]) / (ht[i] - ht[0])))
        [ "$rate" -gt 0 ] && eta="~$(fmt_dur $((data_left / rate)))"
      fi
      if [ "$file_left" -gt 0 ]; then
        disk_pct=$((file_done * 100 / (file_done + file_left)))
        phase="disk+RAM copy: disk ${disk_pct}%, RAM left $(fmt_size "$mem_left")"
      else
        phase="RAM sync (round $iter), left $(fmt_size "$mem_left")"
      fi
      line="$phase | $((rate / 1048576)) MiB/s | ETA $eta"
    else
      line="waiting for libvirt..."
    fi
    if [ "$((now - last_prog))" -ge "$stall" ] && [ "$alerted" = 0 ]; then
      alerted=1
      alert "Migration stalled: no data moved for ${stall}s. Check the peer, the network link and 'virsh domjobinfo $dom'; Ctrl-C offers to abort."
    fi
    printf '\r\033[K[%s] %s' "$(fmt_dur $((now - start)))" "$line"
    sleep 2 & wait $! || true
  done
  wait "$pid" || rc=$?
  trap - INT
  printf '\r\033[K'
  if [ "$rc" -ne 0 ]; then warn "migration failed (exit $rc):"; tail -n 20 "$out" >&2; fi
  rm -f "$out"
  log "Migration command ran for $(fmt_dur $((SECONDS - start)))"
  return "$rc"
}
