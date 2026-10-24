#!/usr/bin/env bash
# Read-only check of this host, optionally compared against the other host.
# Usage: 00-preflight.sh [peer]     peer = ssh target of the other host (e.g. you@laptop.local)
# Run it on both hosts after 01-install.sh. Mismatches in the compared keys are
# the usual reasons live migration fails (see the guide's troubleshooting list).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEER="${1:-}"
need_cmd virsh qemu-system-x86_64

local_facts="$(facts)"
echo "$local_facts"

fail=0
check() { # key expected description
  if ! grep -qx "$1=$2" <<<"$local_facts"; then warn "$3"; fail=1; fi
}
check kvm_access ok "no read/write access to /dev/kvm (is your user in the kvm group? log out and in)"
check default_net_active yes "libvirt 'default' network is not active (run scripts/02-network.sh)"

if [ -n "$PEER" ]; then
  log "Comparing with $PEER"
  peer_facts="$(remote_facts "$PEER")" \
    || die "could not collect facts from $PEER (SSH needs a password, or bash/virsh is missing there; guide Phase 1.2)"
  # Different hosts legitimately differ in uri/libvirt only if something is wrong, so compare all but libvirt.
  if diff <(grep -v '^libvirt=' <<<"$local_facts") <(grep -v '^libvirt=' <<<"$peer_facts"); then
    log "No differences in compared facts"
  else
    warn "Differences above (< local, > $PEER). qemu, newest_q35, secmodels and ovmf_code_size must match for live migration."
    fail=1
  fi
fi

[ "$fail" -eq 0 ] && log "Preflight OK" || { warn "Preflight found problems"; exit 1; }
