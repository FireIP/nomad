# TODO

## Blocking

- [x] **Fix live migration** — fixed. Causes: virtio-net option ROM size mismatch between hosts (`<rom bar='off'/>` on the NIC) and AppArmor missing on one host. Verified in both directions.
- [x] **Slow laptop → NUC migration (20 min vs 3–5 min the other way)** — fixed: QEMU tried the NUC's IPv6 addresses first and each attempt waited for the TCP SYN timeout (two ~9 min stalls). `migrate.sh` now pins `--migrateuri tcp://<peer IPv4>`. Verified.
- [ ] **Slow migrations (busy guest)** — cause found: with a busy guest (YouTube) the RAM dirty rate (~117 MiB/s) matched the Gigabit link (~111 MiB/s), so precopy never converged (453 s, 305 iterations). `--auto-converge` cut it to 221 s (disk ~140 s is near the link floor), with 10–20 s of guest lag at the end.
  - [x] Make `--auto-converge` the default in `scripts/migrate.sh` and add timings to guide Phase 7
  - [ ] Try `fstrim -av` in the guest before migrating, and balloon deflate (guide 8.2), then re-measure with `--monitor`
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

## Guide

- [ ] Keep `nuc-laptop-vm-handoff-guide_v2.md` in sync with the scripts
