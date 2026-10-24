#!/usr/bin/env bash
# Guide Phase 7: live-migrate the VM to the other host, with pre-checks.
# Usage: migrate.sh <peer> [--dry-run]     peer = ssh target of the destination, e.g. you@laptop.local
# Run it on the host that currently runs the VM. Extra virsh migrate flags: MIGRATE_ARGS="...".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEER="${1:-}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1
[ -n "$PEER" ] || die "usage: $0 <peer> [--dry-run]"
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
ssh -o BatchMode=yes "$PEER" "ls -lh /var/lib/libvirt/images/$DOMAIN.qcow2" 2>/dev/null \
  && warn "a disk file already exists on $PEER (see the stale-file note in guide Phase 7)"

[ "$problems" -eq 0 ] || die "pre-checks failed; fix the problems above (nothing was migrated)"

cmd=(virsh migrate --live --persistent --undefinesource --copy-storage-all --verbose ${MIGRATE_ARGS:-}
     "$DOMAIN" "qemu+ssh://$PEER/system")
log "${cmd[*]}"
[ "$DRY_RUN" -eq 1 ] && { log "Dry run, not migrating"; exit 0; }
time "${cmd[@]}"
