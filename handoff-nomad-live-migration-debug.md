# Handoff — `nomad` live migration still failing (NUC → Lifebook)

**Next session's job:** find the real cause of the live-migration failure below. Aligning the QEMU version did **not** fix it, so the current working theory is wrong or incomplete.

## Where things live (don't re-derive these)

- Build guide (canonical, phase-ordered): `/mnt/user-data/outputs/nuc-laptop-vm-handoff-guide.md`. The copy under `/mnt/project/` is stale and lacks Phase 2.6.
- Earlier troubleshooting log from another assistant: `/mnt/user-data/uploads/Perplexity-handoff-unconfirmed.md`. Treat its claims as unverified. Its items 4–5 (OVMF Secure Boot, loader/NVRAM auto-select) and 8 (migration ports 49152–49215) are relevant background.
- The project memory files `overview.md` and `learnings-and-decisions.md` already hold the project state. Read them first.

## Setup

| | NUC (source) | Lifebook S938 (destination) |
|---|---|---|
| OS | Kubuntu 26.04 | Kali rolling |
| QEMU | 10.2.1 (`1:10.2.1+ds-1ubuntu3.2`) | 10.2.1 (`1:10.2.1+ds-1`), downgraded from 11.0.1 via snapshot.debian.org |
| Domain machine type | `pc-q35-10.2` | `pc-q35-10.2` |

- The VM is `nomad`, UEFI (OVMF), on libvirt `qemu:///system`. Graphics are SPICE + virtio, the network is NAT, and the disk is qcow2 with `--copy-storage-all`.
- Laptop SSH alias: `s-938-w`.
- The laptop's QEMU packages are held at `1:10.2.1+ds-1`: `qemu-system-x86`, `qemu-system-common`, `qemu-system-data`, `qemu-utils`, `qemu-block-extra`, `qemu-system-modules-spice`, `qemu-system-modules-opengl`, `qemu-system-gui`. The snapshot is `20260214T023651Z`, pinned at priority 1.
- The user reported the downgrade worked and the install looks fine. I never saw the final `-display help` output after the module packages went back in.

## The failure (identical before and after the QEMU downgrade)

Command, run on the NUC:
```
virsh migrate --live --persistent --undefinesource --copy-storage-all nomad qemu+ssh://s-938-w/system
```
Error (the host locale is German, so "Operation schlug fehl" means "Operation failed"):
```
migration out failed: Sibling indicated error 1
migration in failed: load of migration failed: Invalid argument: error while loading state
for instance 0x0 of device 'ram': Failed to load vmstate version_id: 4, ret: -22
```

## Hypotheses so far

- **Falsified: machine-type ABI mismatch.** The domain is pinned to `pc-q35-10.2` on both hosts, confirmed on the running domain, and the error is unchanged.
- **Insufficient on its own: QEMU version mismatch.** The versions now match and the error is byte-identical. The alignment was still reasonable to do, but it is not the cause.
- **Already resolved earlier:** AppArmor seclabel mismatch, and the NBD/port timeout. The failure now occurs at RAM state load on the destination.

`ret: -22` is EINVAL from `ram` loading. It is a generic wrapper and does not say which condition failed.

## Next steps, in order

1. **Get the real error.** After a failed attempt, read `/var/log/libvirt/qemu/nomad.log` on the **laptop** and the NUC. It probably names the specific RAM block or subsection that failed. This was queued and never run.
2. **Compare the firmware setup on both hosts.** This is an untested hypothesis, but it is the one I would check first.
   - Run `virsh dumpxml nomad | grep -A8 "<os"` and compare `<loader>`/`<nvram>` paths.
   - Compare the edk2/OVMF package versions and the firmware file sizes on both hosts.
   - Different OVMF builds mean different firmware RAM-block sizes, and a block-length mismatch breaks a RAM load. The earlier log already hit Secure Boot and NVRAM problems between these hosts.
3. **Confirm the Phase 2.5 CPU baseline is actually in the running domain.**
   - Run `virsh dumpxml nomad | grep -A4 "<cpu"`.
   - It was never confirmed in this session. If the domain is still `host-model`, fix that, though a CPU mismatch would normally show a different error.
4. **Compare libvirt and kernel versions.** Run `virsh version` and `uname -r` on both hosts. Neither is checked yet.
5. **Compare guest memory configuration.** Look at `<memory>`/`<currentMemory>`, memory backing (hugepages), and the vCPU count in the domain XML.

## Cautions

- In the previous session, three explanations were stated with more confidence than the evidence supported: machine-type ABI, QEMU version, and "apt would block removal of the SPICE module packages if they were needed". All three turned out wrong or incomplete. Label hypotheses as hypotheses and test one at a time.
- **The guide overclaims.** Phase 2.6, the Phase 7 pointer and one troubleshooting entry present a QEMU version mismatch as *the* signature of this error, which is now known to be false. Reword them once the real cause is found.
- Cold migration (guide Phase 6) works and is the interim daily fallback. Nothing is blocked on live migration.

## Working style

- The user wants evidence-driven troubleshooting, with hypotheses tested and then confirmed or falsified before moving on.
- The user wants the tradeoffs explained before committing, and pushes back on over-engineering.
- The guide is kept up to date as findings arrive.

## Suggested skills

- No skill is needed for the diagnosis. It is shell commands, log reading and XML comparison.
- Guide edits are plain Markdown. If the user later wants the guide as Word or PDF, use `docx` or `pdf`.
