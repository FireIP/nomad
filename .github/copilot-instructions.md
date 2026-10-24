# Copilot Instructions

This repo is not a software project: there is no build, test, or lint tooling. It is the documentation and libvirt config for "nomad", a single KVM/QEMU workstation VM that live-migrates between a NUC (i7-12700H, 64GB) and a laptop (Fujitsu S938, Kaby Lake R, 24GB). Both hosts keep their normal OS with libvirt layered on top.

## Project status

- **Live migration works in both directions, but is slow.** It was fixed by `<rom bar='off'/>` on the NIC (the virtio-net option ROM differs in size between the hosts) and by having AppArmor on both hosts (see `FIX-apparmor-migration.md`). The generic `ram ... ret: -22` error hides the real cause, so read `/var/log/libvirt/qemu/nomad.log` on the destination. `scripts/collect-migration-info.sh` gathers the comparison data from a host. Slow handoffs are an open TODO.
- **Setup scripts live in `scripts/`** (`lib.sh`, `00-preflight.sh`, `01-install.sh`, `02-network.sh`, `03-cpu-baseline.sh`, `04-nfs.sh` (optional; NFS isn't set up), `05-create-vm.sh`, `migrate.sh`, plus the debug helper `collect-migration-info.sh`). They mirror the guide's phases and haven't been run end to end on the real hosts yet. Change a script and the matching guide phase together, keep them idempotent and safe to run on either host (NUC or laptop), and check syntax with `bash -n scripts/*.sh`. Scripts source `lib.sh`, which sets `LC_ALL=C` and `qemu:///system`.

## Layout and how the pieces relate

- `nuc-laptop-vm-handoff-guide_v2.md` is the **current** build guide (Phases 0–8 plus a troubleshooting checklist). `nuc-laptop-vm-handoff-guide.md` and `_v1-5.md` are older revisions kept for history; make guide edits in `_v2` only.
- The CPU XML files are the artifacts of guide Phase 2, and they form a pipeline:
  1. `nuc-cpu-raw.xml` and `laptop-cpu-raw.xml` come from `virsh domcapabilities --machine q35 --arch x86_64 --virttype kvm | xmllint --xpath "//cpu/mode[@name='host-model']"`.
  2. `nuc-cpu.xml` and `laptop-cpu.xml` are the same files with the outer `<mode …>` tag renamed to `<cpu>`.
  3. `both-cpus.xml` is the two concatenated.
  4. `baseline-cpu.xml` is the output of `virsh hypervisor-cpu-baseline both-cpus.xml --migratable`.
  5. The `<cpu>` block of `nomad.xml` is that baseline: a `Skylake-Client-IBRS` custom model, `match='exact'`, with `hle`, `rtm`, and `mpx` disabled.
- `nomad.xml` is a `virsh dumpxml nomad` snapshot of the real domain. `nomad_VARS.fd` is its UEFI NVRAM, which holds Secure Boot keys and boot entries. Treat both as exported state, not hand-authored source.

## Conventions and constraints to preserve

- **Migration safety comes from the CPU baseline.** The laptop's older feature set is the ceiling, so never put `host-model` or `host-passthrough` in the final domain XML. If a CPU file changes, regenerate the whole chain above and re-verify with `virsh hypervisor-cpu-compare baseline-cpu.xml --virttype kvm --arch x86_64 --machine q35` (or `scripts/03-cpu-baseline.sh verify`) on both hosts. Keep the baseline in the guide (2.5), `baseline-cpu.xml`, and `nomad.xml` in sync.
- **`qemu:///system` is assumed everywhere.** Every `virsh` example relies on it, and the guide calls out `qemu:///session` as a silent failure mode (Phase 1.4).
- **Hardware must be identical on both hosts for migration.** The guest uses q35 with UEFI, virtio-scsi disks with `discard=unmap`, virtio net (with `<rom bar='off'/>`, required because the option ROM size differs per distro) on libvirt's `default` NAT network, virtio-gpu video with no 3D, SPICE graphics, and a qemu-guest-agent channel. The guest has a static IP (`192.168.122.50/24`, gateway `.1`) so it looks the same on either host. Don't add host-specific devices (GPU or USB passthrough, bridges tied to one NIC).
- **Disk stays lean.** `--copy-storage-all` copies the whole qcow2 on every handoff, so the guide keeps the disk to about 60GB or less and puts bulk data on an NFS export from the NUC. The guest mounts it with `soft,nofail,_netdev`, so it never hangs when the NUC is unreachable.
- **The daily migration command is `virsh migrate --live --persistent --undefinesource --copy-storage-all nomad qemu+ssh://you@<host>/system`.**
- **Placeholders stay generic.** The guide uses `you@laptop.local`, `you@nuc.local`, and `/path/to/your-installer.iso`. Keep them rather than inserting real usernames or hosts.
- **Guide style.** The guide is written in the second person, as ordered phases with copy-pasteable shell and XML blocks. Hardware-specific numbers (RAM sizes, vCPU counts, `<memory>`, `current=` values) must stay consistent across the prose, the `virt-install` command, and the Phase 8 hotplug and balloon examples. Currently that is 12GiB and 6 vCPUs at the laptop, growing to 40GiB and 16 vCPUs at the NUC.
