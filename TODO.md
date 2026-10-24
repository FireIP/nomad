# TODO

## Blocking

- [ ] **Fix live migration** — `virsh migrate --live --persistent --undefinesource --copy-storage-all nomad qemu+ssh://you@<host>/system` currently fails.
  - [ ] Capture the exact error output and which direction fails (NUC → laptop, laptop → NUC, or both)
  - [ ] Re-run `virsh cpu-compare baseline-cpu.xml` on both hosts
  - [ ] Confirm `virsh uri` prints `qemu:///system` on both hosts
  - [ ] Confirm a cold migration round trip works (Phase 6)
  - [ ] Check the stale destination qcow2 case (Phase 7 note)
  - [ ] Update the guide with the root cause and fix

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
