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
