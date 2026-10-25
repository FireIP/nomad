#!/usr/bin/env bash
# Guide 8.1/8.2: grow the running VM to the NUC's size, or shrink it back, or show its size.
# Usage: inflate.sh [inflate|deflate|status]      (default: inflate)
# Env: INFLATE_VCPUS / INFLATE_MEM_KIB (default: the domain's maximums, 16 / 32 GiB),
#      TARGET_VCPUS (6) / TARGET_MEM_KIB (12582912) for deflate, RESERVE_KIB (4194304) left to the host, TIMEOUT (300).
# Inflate refuses if this host can't afford it, so running it on the laptop is harmless.
# migrate.sh deflates by itself before migrating.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need_cmd virsh
TARGET_VCPUS="${TARGET_VCPUS:-6}"
TARGET_MEM_KIB="${TARGET_MEM_KIB:-12582912}"
RESERVE_KIB="${RESERVE_KIB:-4194304}"
TIMEOUT="${TIMEOUT:-300}"

[ "$(vm_state "$DOMAIN")" = "running" ] || die "'$DOMAIN' is not running on this host"

status() {
  echo "$DOMAIN: $(cur_vcpus "$DOMAIN")/$(max_vcpus "$DOMAIN") vCPUs, $(($(cur_mem_kib "$DOMAIN") / 1024))/$(($(max_mem_kib "$DOMAIN") / 1024)) MiB (current/max)"
}

case "${1:-inflate}" in
  status) status ;;
  inflate)
    vcpus="${INFLATE_VCPUS:-$(max_vcpus "$DOMAIN")}"
    mem="${INFLATE_MEM_KIB:-$(max_mem_kib "$DOMAIN")}"
    [ "$vcpus" -le "$(max_vcpus "$DOMAIN")" ] && [ "$mem" -le "$(max_mem_kib "$DOMAIN")" ] \
      || die "requested size exceeds the domain's maximums; shut down and raise them (guide 8.1/8.2)"
    host_cpus="$(nproc)"
    host_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    delta=$((mem - $(cur_mem_kib "$DOMAIN")))
    [ "$vcpus" -le "$host_cpus" ] || die "this host has only $host_cpus CPU threads, can't give the guest $vcpus"
    [ "$delta" -le 0 ] || [ "$((host_avail - RESERVE_KIB))" -ge "$delta" ] \
      || die "this host has only $((host_avail / 1024)) MiB available; need $((delta / 1024)) MiB more plus $((RESERVE_KIB / 1024)) MiB reserve"
    status
    log "Inflating to $vcpus vCPUs, $((mem / 1024)) MiB"
    resize_guest "$DOMAIN" "$vcpus" "$mem" "$TIMEOUT" || die "guest did not reach the target"
    status
    ;;
  deflate)
    status
    log "Deflating to $TARGET_VCPUS vCPUs, $((TARGET_MEM_KIB / 1024)) MiB"
    resize_guest "$DOMAIN" "$TARGET_VCPUS" "$TARGET_MEM_KIB" "$TIMEOUT" || die "guest did not reach the target (free memory in the guest and retry)"
    status
    ;;
  *) die "usage: $0 [inflate|deflate|status]" ;;
esac
