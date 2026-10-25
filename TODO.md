# TODO

## Blocking

- [x] **Fix live migration** — fixed. Causes: virtio-net option ROM size mismatch between hosts (`<rom bar='off'/>` on the NIC) and AppArmor missing on one host. Verified in both directions.
- [x] **Slow laptop → NUC migration (20 min vs 3–5 min the other way)** — fixed: QEMU tried the NUC's IPv6 addresses first and each attempt waited for the TCP SYN timeout (two ~9 min stalls). `migrate.sh` now pins `--migrateuri tcp://<peer IPv4>`. Verified.
- [ ] **Slow migrations (busy guest)** — cause found: with a busy guest (YouTube) the RAM dirty rate (~117 MiB/s) matched the Gigabit link (~111 MiB/s), so precopy never converged (453 s, 305 iterations). `--auto-converge` cut it to 221 s (disk ~140 s is near the link floor), with 10–20 s of guest lag at the end.
  - [x] Make `--auto-converge` the default in `scripts/migrate.sh` and add timings to guide Phase 7
  - [x] Try `fstrim -av` in the guest before migrating, and balloon deflate (guide 8.2), then re-measure with `--monitor`: balloon deflate is built into `migrate.sh` (3 min 22–27 s total); `fstrim` reports ~40 GB but the qcow2 was already ~12 GB (`du`), so there is nothing to gain. The ~2.5 min disk phase is the Gigabit floor; only less allocated data or a faster link helps
  - [x] Add `migration-*.log` to `.gitignore`
  - [ ] (optional) Compression/multifd, only if still too slow: `--parallel --parallel-connections N`, zstd (check `virsh migrate --help` on both hosts first); CPU cost lands on the weaker laptop
  - [ ] (optional) Raise the allowed final pause with `virsh migrate-setmaxdowntime nomad <ms>` during migration, so precopy converges sooner at the cost of a longer pause
    - [ ] (optional) Direct 2.5GbE cable or a 2.5GbE switch between the hosts (needs an adapter for the laptop; NUC already has 2.5GbE). `migrate.sh` already pins `--migrateuri tcp://<peer IPv4>`, so a direct link only needs its address as the peer; SSH overhead was not the limit
  - [ ] (optional) Keep the guest quiet before migrating: close video and heavy apps, or add a pre-migration hint to `migrate.sh`
  - [ ] (optional) Keep the allocated disk small: move bulk data to NFS (`04-nfs.sh`), clean caches and old kernels in the guest, `fstrim` regularly
  - [ ] (optional, risky, probably not) Post-copy (`--postcopy`): switches execution to the destination early. Avoid: a network drop mid-migration can lose the VM, and it's unclear it combines with `--copy-storage-all`
  - [ ] (optional) 2.5GbE adapter for the laptop (NUC already has 2.5GbE)
  - [ ] (optional, experiment) Overlay qcow2 on a shared read-only base + `--copy-storage-inc`: could cut the ~140 s disk phase to seconds, but needs a byte-identical base on both hosts, periodic `blockcommit` and base re-sync, and changes the disk layout in the guide, `nomad.xml` and scripts. Try on a throwaway VM first.
- [x] Guest clocksource verified as `kvm-clock`
- [x] Stale destination qcow2 is overwritten cleanly by `--copy-storage-all` (confirmed)

## Setup scripts

- [x] Scripts written in `scripts/` for Phases 1, 2, 3 (optional), 4 and 7
- [x] Tested on both hosts: `00-preflight.sh <peer>`, `03-cpu-baseline.sh extract|baseline|verify`, `migrate.sh <peer> --dry-run`
- [ ] Test `02-network.sh [peer]` on both hosts
- [ ] Test a real `migrate.sh <peer>` in both directions
- [x] Update guide Phase 2.4 to use `hypervisor-cpu-compare` (plain `cpu-compare` gave a false "incompatible")
- [ ] (only if NFS gets set up) Set up NFS with `04-nfs.sh server`, test it, then add the `/mnt/bulk` mount in the guest
- [x] Keep `collect-migration-info.sh` as a standalone debug helper
- [ ] (low priority) Test `01-install.sh` on a host (safe to re-run; check it doesn't repeat group or `~/.bashrc` changes)
- [ ] (low priority) Test `05-create-vm.sh create` and `apply-baseline` with a throwaway domain (`DOMAIN=nomad-test IMG=/var/lib/libvirt/images/nomad-test.qcow2`), then remove it with `virsh undefine nomad-test --nvram`

## Phase 8 (performance, next up)

- [x] 8.1 vCPU hotplug: `<vcpu placement='static' current='6'>16</vcpu>`; `setvcpus nomad 16 --live` / `6 --live` verified, guest udev rule onlines CPUs (guide Phase 5), laptop accepts the 16-vCPU max, `nomad.xml` updated
- [x] 8.2 Memory ballooning: `<memory>` 33554432 KiB (32 GiB), `<currentMemory>` 12582912 KiB (12 GiB); `setmem` verified, laptop (24 GB) accepts the 32 GiB max, `migrate.sh` deflates first, `nomad.xml` updated
- [x] `scripts/inflate.sh [inflate|deflate|status]` for easy inflating (untested on the real hosts)
- [x] Decide whether `migrate.sh` should auto-deflate: done, it deflates to 6 vCPUs / 12 GiB and waits (`NO_DEFLATE=1` skips); `05-create-vm.sh apply-limits` added. Migration to and from the laptop works
- [x] Re-measure migration time with `--monitor` after 8.2: NUC → laptop 3 min 27 s (+~30 s deflate while playing YouTube), laptop → NUC 3 min 22 s, YouTube kept playing (was 221 s with auto-converge before)
- [x] Numbers checked (12 GiB/6 vCPU at the laptop, 32 GiB/16 vCPU at the NUC): guide 8.1/8.2, `nomad.xml` and `05-create-vm.sh` agree

- [ ] Multiple monitors for the VM: add a second video head (`<video><model type='virtio' heads='2'/></video>` in `nomad.xml`, same on both hosts) and open it with `remote-viewer` / `virt-viewer --connect qemu:///system nomad` (multi-monitor via SPICE, `spice-vdagent` in the guest). Check it survives migration and that the laptop's own display plus an external monitor work. Update guide Phase 4/8 and `05-create-vm.sh` if it works

## `nomad` command

- [x] `scripts/nomad` (`start`, `migrate`, `inflate`, `deflate`, `status`) and `scripts/06-install-tools.sh`; route probing (eth then wifi), progress/ETA, stall alerts, auto-inflate on arrival (`nomad migrate` and `06-install-tools.sh` verified on the real hosts)
- [x] Tested on the real hosts: `nomad migrate` both ways, `nomad start`, Ctrl-C abort, wifi fallback
- [ ] Test the stall alert (no data for `STALL_SECS`: bell, red message, desktop notification)
- [x] `nomad start` / `nomad migrate` open the console (`nomad viewer`, `VIEWER`/`VIEWER_CMD` in the config): locally on start, on the destination after migrate (a viewer on the source too is opt-in with `VIEWER_SOURCE=1`: SPICE is single-client, so two viewers disconnect/freeze each other). Untested on the real hosts (destination GUI-session launch over ssh, SPICE over ssh)
- [ ] Test the auto-opened console on the real hosts, then multiple monitors (see the multi-monitor item above)

## Guide

- [ ] Keep `nuc-laptop-vm-handoff-guide_v2.md` in sync with the scripts
