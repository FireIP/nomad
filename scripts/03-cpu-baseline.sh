#!/usr/bin/env bash
# Guide Phase 2: build and verify the portable CPU baseline.
# Usage:
#   03-cpu-baseline.sh extract <nuc|laptop>   on each host: writes <name>-cpu-raw.xml and <name>-cpu.xml
#   03-cpu-baseline.sh baseline               on one host, after copying both <name>-cpu.xml files next to each other:
#                                             writes both-cpus.xml and baseline-cpu.xml
#   03-cpu-baseline.sh verify                 on BOTH hosts: virsh cpu-compare baseline-cpu.xml
# Files go to $OUT_DIR (default: the repo root). Re-running overwrites them, and baseline-cpu.xml
# must then be kept in sync with the guide (2.5) and nomad.xml.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd="${1:-}"
case "$cmd" in
  extract)
    name="${2:-}"
    [[ "$name" == nuc || "$name" == laptop ]] || die "usage: $0 extract <nuc|laptop>"
    need_cmd virsh xmllint
    virsh domcapabilities --machine q35 --arch x86_64 --virttype kvm \
      | xmllint --xpath "//cpu/mode[@name='host-model']" - > "$OUT_DIR/$name-cpu-raw.xml"
    echo >> "$OUT_DIR/$name-cpu-raw.xml"
    # Rename the outer <mode ...> tag to <cpu>
    sed -e '1s/^<mode [^>]*>/<cpu>/' -e 's#</mode>#</cpu>#' \
      "$OUT_DIR/$name-cpu-raw.xml" > "$OUT_DIR/$name-cpu.xml"
    grep -q '^<cpu>' "$OUT_DIR/$name-cpu.xml" || die "unexpected raw CPU XML, check $OUT_DIR/$name-cpu-raw.xml"
    log "Wrote $OUT_DIR/$name-cpu.xml"
    ;;
  baseline)
    need_cmd virsh
    [ -f "$OUT_DIR/nuc-cpu.xml" ] && [ -f "$OUT_DIR/laptop-cpu.xml" ] \
      || die "need nuc-cpu.xml and laptop-cpu.xml in $OUT_DIR (run 'extract' on each host and copy the files)"
    cat "$OUT_DIR/nuc-cpu.xml" "$OUT_DIR/laptop-cpu.xml" > "$OUT_DIR/both-cpus.xml"
    if ! virsh hypervisor-cpu-baseline "$OUT_DIR/both-cpus.xml" --migratable > "$OUT_DIR/baseline-cpu.xml" 2>/dev/null; then
      log "hypervisor-cpu-baseline unavailable, falling back to cpu-baseline"
      virsh cpu-baseline "$OUT_DIR/both-cpus.xml" --migratable > "$OUT_DIR/baseline-cpu.xml"
    fi
    log "Wrote $OUT_DIR/baseline-cpu.xml. Now run '$0 verify' on both hosts."
    ;;
  verify)
    need_cmd virsh
    [ -f "$OUT_DIR/baseline-cpu.xml" ] || die "no baseline-cpu.xml in $OUT_DIR"
    # hypervisor-cpu-compare asks QEMU/KVM what it can really provide; plain cpu-compare only
    # looks at libvirt's host CPU description and can flag guest-only features as unsupported.
    if virsh help hypervisor-cpu-compare >/dev/null 2>&1; then
      virsh hypervisor-cpu-compare "$OUT_DIR/baseline-cpu.xml" --virttype kvm --arch x86_64 --machine q35
    else
      virsh cpu-compare "$OUT_DIR/baseline-cpu.xml"
    fi
    ;;
  *)
    die "usage: $0 extract <nuc|laptop> | baseline | verify"
    ;;
esac
