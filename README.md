# Nomad

Nomad is a Linux workstation VM intended to move between a home NUC and a
portable laptop using libvirt/QEMU live migration. This repository contains
the VM definition, CPU compatibility data, firmware state, and setup notes for
that two-host configuration; it is not an application source tree.

## Project status

The checked-in domain definition, [`nomad.xml`](nomad.xml), describes an
Ubuntu 24.04 guest configured for 6 vCPUs, 12 GiB of memory, UEFI Secure Boot,
virtio graphics, and libvirt's `default` NAT network. Its CPU model is pinned
to a custom Skylake-Client-IBRS baseline to support migration between the
hosts. The configured disk path is
`/var/lib/libvirt/images/nomad.qcow2`.

These files are a configuration snapshot, not evidence that the guest is
currently running or that migration has been tested successfully. Review the
domain XML and adapt host-specific paths, network setup, and hardware details
before using it on another machine.

## Setup guide

Start with the [NUC ↔ Laptop Workstation Handoff Guide, v2](nuc-laptop-vm-handoff-guide_v2.md).
It covers host preparation, CPU-baseline generation and verification, disk
layout, VM installation, and cold and live migration. The other
[`nuc-laptop-vm-handoff-guide.md`](nuc-laptop-vm-handoff-guide.md) and
[`nuc-laptop-vm-handoff-guide_v1-5.md`](nuc-laptop-vm-handoff-guide_v1-5.md)
files are retained historical guide revisions; use v2 as the main reference.

## Repository files

| File | Purpose |
| --- | --- |
| [`nomad.xml`](nomad.xml) | Libvirt domain definition for the VM |
| [`nomad_VARS.fd`](nomad_VARS.fd) | UEFI variable store associated with the VM |
| [`nuc-cpu-raw.xml`](nuc-cpu-raw.xml), [`laptop-cpu-raw.xml`](laptop-cpu-raw.xml) | Raw host CPU capability data |
| [`nuc-cpu.xml`](nuc-cpu.xml), [`laptop-cpu.xml`](laptop-cpu.xml) | Normalized CPU descriptions used to calculate the common baseline |
| [`both-cpus.xml`](both-cpus.xml) | Combined CPU input used for baseline calculation |
| [`baseline-cpu.xml`](baseline-cpu.xml) | Portable CPU model used in the domain definition |
| `nuc-laptop-vm-handoff-guide*.md` | Current and historical setup guides |

The XML files record host- and VM-specific details. Recompute the CPU baseline
if either host changes, and keep the VM definition and its firmware variable
store together when preserving or moving this VM configuration.

## Script tests

Run the same checks as GitHub Actions:

```sh
for script in scripts/*.sh scripts/nomad; do bash -n "$script" || break; done
python3 -B -m unittest discover -s tests -v
```

The tests use Python's standard library and temporary, simulated hosts with
stubbed `virsh`, `ssh`, migration and XML-query commands
(`tests/stubs/host-command.py`). They cover offline starts (including terminal
confirmation), ownership records, migration outcomes and locking, dry runs,
takeover and conflicting copies, and non-default `DOMAIN` state, without
contacting real hosts or using libvirt. They do not replace testing actual
migration on both machines.

## License

See [LICENSE](LICENSE).
