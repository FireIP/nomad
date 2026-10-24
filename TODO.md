# TODO

## Blocking

- [x] **Fix live migration** — fixed. Causes: virtio-net option ROM size mismatch between hosts (`<rom bar='off'/>` on the NIC) and AppArmor missing on one host. Verified in both directions.
- [ ] **Investigate slow migrations** — both directions took very long. Measure where time goes (full 60GB qcow2 copy vs. RAM), check disk usage and network throughput, consider `--compressed` or a smaller disk.
- [ ] Verify guest clocksource is `kvm-clock` and time stays correct after migration (TSC scaling warning on the laptop)
- [ ] Re-test the stale destination qcow2 case (Phase 7 note)

## Setup scripts

- [x] Scripts written in `scripts/` for Phases 1, 2, 3 (optional), 4 and 7
- [x] Tested on both hosts: `00-preflight.sh <peer>`, `03-cpu-baseline.sh extract|baseline|verify`, `migrate.sh <peer> --dry-run`
- [ ] Test `02-network.sh [peer]` on both hosts
- [ ] Test a real `migrate.sh <peer>` in both directions
- [x] Update guide Phase 2.4 to use `hypervisor-cpu-compare` (plain `cpu-compare` gave a false "incompatible")
- [ ] (only if NFS gets set up) Set up NFS with `04-nfs.sh server`, test it, then add the `/mnt/bulk` mount in the guest
- [ ] Decide whether to drop `collect-migration-info.sh` now that debugging is done
- [ ] (low priority) Test `01-install.sh` on a host (safe to re-run; check it doesn't repeat group or `~/.bashrc` changes)
- [ ] (low priority) Test `05-create-vm.sh create` and `apply-baseline` with a throwaway domain (`DOMAIN=nomad-test IMG=/var/lib/libvirt/images/nomad-test.qcow2`), then remove it with `virsh undefine nomad-test --nvram`

## Guide

- [ ] Keep `nuc-laptop-vm-handoff-guide_v2.md` in sync with the scripts
