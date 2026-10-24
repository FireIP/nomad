#!/usr/bin/env bash
# Read-only diagnostics for the nomad live-migration failure.
# Run on BOTH hosts (as a user in the libvirt group; sudo only for firmware files and the log tail)
# and compare the output. Usage: ./collect-migration-info.sh [domain] > "$(hostname)-info.txt"
export LC_ALL=C
DOM="${1:-nomad}"
VIRSH="virsh --connect qemu:///system"

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1; }

section "Host"
run hostname
run uname -r
run virsh uri
run $VIRSH version

section "QEMU / firmware packages"
run qemu-system-x86_64 --version
dpkg -l 2>/dev/null | grep -E '^ii +(ovmf|edk2|qemu-system-x86|qemu-system-data|swtpm|libvirt-daemon-system) ' | awk '{print $2, $3}'

section "Firmware files"
for f in /usr/share/OVMF/OVMF_CODE_4M.ms.fd /usr/share/OVMF/OVMF_VARS_4M.ms.fd \
         "/var/lib/libvirt/qemu/nvram/${DOM}_VARS.fd"; do
  if sudo test -e "$f"; then
    sudo sha256sum "$f"
    sudo stat -c '%n %s bytes' "$f"
  else
    echo "missing: $f"
  fi
done

section "Domain: os / cpu / memory / vcpu"
$VIRSH dumpxml "$DOM" 2>&1 | grep -E -A8 '<os' | head -20
$VIRSH dumpxml "$DOM" 2>&1 | grep -E '<memory|<currentMemory|<vcpu|<memoryBacking|<hugepages|machine='
$VIRSH dumpxml "$DOM" 2>&1 | grep -E -A3 '<cpu '

section "Machine types supported"
$VIRSH capabilities 2>&1 | grep -o 'pc-q35-[0-9.]*' | sort -uV | tail -5

section "Domain state"
run $VIRSH domstate "$DOM"

section "Last 60 lines of QEMU domain log (look for the real RAM/block error)"
sudo tail -n 60 "/var/log/libvirt/qemu/${DOM}.log" 2>&1
