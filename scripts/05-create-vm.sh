#!/usr/bin/env bash
# Guide Phase 4: create the VM, then swap in the migratable CPU baseline.
# Usage:
#   05-create-vm.sh create --iso /path/to/your-installer.iso   run on the NUC or laptop, once
#   (finish the OS install in the guest, then shut it down)
#   05-create-vm.sh apply-baseline                             replaces <cpu> with baseline-cpu.xml
# Env: MEM_MB (12288), VCPUS (6), DISK_GB (60), IMG (/var/lib/libvirt/images/nomad.qcow2).
# These must stay consistent with the guide and nomad.xml.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MEM_MB="${MEM_MB:-12288}"
VCPUS="${VCPUS:-6}"
DISK_GB="${DISK_GB:-60}"
IMG="${IMG:-/var/lib/libvirt/images/nomad.qcow2}"

case "${1:-}" in
  create)
    [ "${2:-}" = "--iso" ] && [ -n "${3:-}" ] || die "usage: $0 create --iso /path/to/your-installer.iso"
    iso="$3"
    need_cmd virsh virt-install qemu-img
    [ -f "$iso" ] || die "ISO not found: $iso"
    if vm_exists "$DOMAIN"; then
      log "Domain '$DOMAIN' already exists on this host, nothing to do"
      exit 0
    fi
    if [ -e "$IMG" ]; then
      warn "$IMG already exists, reusing it"
    else
      sudo qemu-img create -f qcow2 "$IMG" "${DISK_GB}G"
    fi
    # --cpu host-model is only a placeholder for the install; apply-baseline replaces it.
    virt-install \
      --name "$DOMAIN" \
      --memory "$MEM_MB" \
      --vcpus "$VCPUS" \
      --cpu host-model \
      --machine q35 \
      --boot uefi \
      --disk "path=$IMG,bus=scsi,discard=unmap" \
      --controller type=scsi,model=virtio-scsi \
      --network network=default,model=virtio,rom.bar=off \
      --graphics spice \
      --video virtio \
      --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
      --os-variant detect=on,require=on \
      --cdrom "$iso"
    ;;
  apply-baseline)
    need_cmd virsh python3
    baseline="$OUT_DIR/baseline-cpu.xml"
    [ -f "$baseline" ] || die "no $baseline (see scripts/03-cpu-baseline.sh)"
    vm_exists "$DOMAIN" || die "domain '$DOMAIN' does not exist on this host"
    [ "$(vm_state "$DOMAIN")" = "shut off" ] || die "shut '$DOMAIN' down first (virsh shutdown $DOMAIN)"
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    virsh dumpxml --inactive "$DOMAIN" | python3 -c '
import sys, xml.etree.ElementTree as ET
ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
dom = ET.parse(sys.stdin).getroot()
new = ET.parse(sys.argv[1]).getroot()
old = dom.find("cpu")
idx = list(dom).index(old) if old is not None else len(dom)
if old is not None:
    dom.remove(old)
dom.insert(idx, new)
sys.stdout.write(ET.tostring(dom, encoding="unicode"))
' "$baseline" > "$tmp"
    virsh define "$tmp"
    log "Baseline applied. Verify with: virsh dumpxml $DOMAIN | grep -A3 '<cpu'"
    ;;
  *)
    die "usage: $0 create --iso /path/to.iso | apply-baseline"
    ;;
esac
