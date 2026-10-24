#!/usr/bin/env bash
# Guide Phase 1.2 + 1.3: make sure libvirt's 'default' NAT network is active and
# autostarting, and optionally verify passwordless SSH to the other host.
# Usage: 02-network.sh [peer]     peer = e.g. you@laptop.local
# Idempotent; run on both hosts. It does not change the subnet; both hosts must report
# the same one (default 192.168.122.0/24), see 00-preflight.sh <peer>.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEER="${1:-}"
need_cmd virsh

virsh net-info default >/dev/null 2>&1 || die "libvirt network 'default' is not defined on this host"

if [ "$(virsh net-info default | awk '/Active:/{print $2}')" != "yes" ]; then
  log "Starting default network"
  virsh net-start default
fi
if [ "$(virsh net-info default | awk '/Autostart:/{print $2}')" != "yes" ]; then
  log "Enabling autostart for default network"
  virsh net-autostart default
fi
log "default network: $(virsh net-dumpxml default | grep -o "<ip address='[0-9.]*' netmask='[0-9.]*'" | head -n1)"

if [ -n "$PEER" ]; then
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$PEER" true 2>/dev/null; then
    log "SSH to $PEER works without a prompt"
  else
    warn "SSH to $PEER needs a prompt or fails. Run: ssh-keygen -t ed25519 (if no key), then ssh-copy-id $PEER"
    exit 1
  fi
fi
