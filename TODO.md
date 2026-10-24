# TODO

## Blocking

- [x] **Fix live migration** — fixed. Causes: virtio-net option ROM size mismatch between hosts (`<rom bar='off'/>` on the NIC) and AppArmor missing on one host. Verified in both directions.
- [ ] **Investigate slow migrations** — both directions took very long. Measure where time goes (full 60GB qcow2 copy vs. RAM), check disk usage and network throughput, consider `--compressed` or a smaller disk.
- [ ] Verify guest clocksource is `kvm-clock` and time stays correct after migration (TSC scaling warning on the laptop)
- [ ] Re-test the stale destination qcow2 case (Phase 7 note)

## Setup scripts

- [ ] Package install and group setup (Phase 1.1)
- [ ] SSH key exchange check (Phase 1.2)
- [ ] `default` network check and subnet match (Phase 1.3)
- [ ] `qemu:///system` default URI check (Phase 1.4)
- [ ] CPU baseline generation and `cpu-compare` verification (Phase 2)
- [ ] NFS export on the NUC and guest mount (Phase 3)
- [ ] VM creation and baseline CPU swap (Phase 4)
- [ ] Live migration wrapper (Phase 7)
- [ ] Make all scripts idempotent and safe to run on either host

## Guide

- [ ] Keep `nuc-laptop-vm-handoff-guide_v2.md` in sync with the scripts
- [ ] Mark Phase 7 as unverified until migration works
