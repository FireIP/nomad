# NUC ↔ Laptop Workstation Handoff — Build Guide

**Goal:** A single Linux VM ("the workstation") that lives on the NUC's fast storage while you're docked at home, and migrates over to the laptop — live, with open apps intact — when it's time to leave. Neither machine gets reinstalled; both keep their normal host OS with libvirt/QEMU/KVM layered on top.

**Machines:**
- NUC12SNKi72 ("nuc") — i7-12700H, 14c/20t, 64GB DDR4-3200 installed, 2.5GbE — the workhorse.
- Fujitsu Lifebook S938 ("laptop") — 8th-gen Kaby Lake R (i5/i7-8xxxU), 4c/8t, 24GB RAM installed, Gigabit Ethernet — the portable endpoint.

---

## What to actually expect

Read this before you start, so nothing here is a surprise mid-build:

- **CPU/RAM/disk performance really will be much better docked at the NUC.** That gap is real and substantial.
- **Graphics performance will *not* improve at the NUC**, at least not initially. The VM uses virtual graphics (virtio-gpu, no 3D acceleration) so it can migrate at all — compositing, video, anything GPU-bound will feel similar on both hosts regardless of which one is actually running it. 3D acceleration (virgl) is possible later as an add-on, but it's not part of the base build.
- **The first live migration will be slow-ish** because the whole disk has to copy once. Subsequent ones are fast if you keep the migrated disk lean (see Phase 3) — a few minutes, not tens of minutes.
- **This only works when both machines are up and reachable on the same network at the moment you migrate.** It's a "you're home, about to leave" tool, not something that helps while the laptop is already out and about.
- **Bulk data (large files, archives, media) should live outside the migrated disk.** More in Phase 3.

---

## Setup scripts

The `scripts/` directory automates most of the steps below. They are idempotent and safe to run on either host, but have not been run end to end yet; the manual commands in each phase remain the reference.

| Script | Phase | Run on |
|---|---|---|
| `01-install.sh` | 1.1, 1.4 | both |
| `02-network.sh [peer]` | 1.2, 1.3 | both |
| `00-preflight.sh [peer]` | checks | both (compares hosts when given a peer) |
| `03-cpu-baseline.sh extract\|baseline\|verify` | 2 | extract and verify on both, baseline on one |
| `04-nfs.sh server\|fstab` | 3 (optional) | NUC |
| `05-create-vm.sh create\|apply-baseline` | 4 | one host |
| `migrate.sh <peer> [--dry-run] [--monitor]` | 7 | the host currently running the VM (`--monitor` logs job stats to find slow phases) |

---

## Phase 0 — Before you start

**Confirmed RAM:** laptop has 24GB installed, NUC has 64GB. That resolves the ambiguity in the S938's published specs (sources disagreed anywhere from 16GB to 20GB) — good that this got checked against the real machine rather than a spec sheet. 24GB gives comfortable room to size the VM's baseline memory well below it while still leaving plenty for the laptop's own desktop environment — see Phase 4.

**Confirm SSH access will work both ways** — you'll set this up properly in Phase 1, but make sure both machines can already reach each other by hostname or IP on the network you'll be testing from.

---

## Phase 1 — Base setup (both machines)

### 1.1 Install packages

```bash
# Debian/Ubuntu
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients virtinst virt-manager ovmf

# Fedora
sudo dnf install @virtualization

# Arch
sudo pacman -S qemu-full libvirt virt-install virt-manager edk2-ovmf
```

```bash
sudo usermod -aG libvirt,kvm $USER
# log out and back in for group membership to take effect
```

**Ubuntu note:** `qemu-kvm` is a virtual package with two providers — `qemu-system-x86` and, on newer/HWE-enabled systems, `qemu-system-x86-hwe`. If `apt` refuses to pick one automatically, install the specific one explicitly, e.g. `sudo apt install qemu-system-x86-hwe ...` on newer hardware. Both are the same underlying QEMU release, just packaged against different kernel-enablement pockets — doesn't affect anything else in this guide.

### 1.2 SSH keys, both directions

Migration rides over `qemu+ssh://`, which tunnels the whole data stream — no extra ports to open, no separate TLS setup.

```bash
ssh-keygen -t ed25519          # skip if you already have a key
ssh-copy-id you@laptop.local   # run from the NUC
ssh-copy-id you@nuc.local      # run from the laptop
```

Confirm both directions connect with zero prompts before moving on. If `virsh` throws permission errors later despite being in the `libvirt` group, check that libvirt's bundled polkit rules are active for your distro before reaching for `sudo` everywhere — that's the usual culprit.

### 1.3 Confirm the default network, and make it look consistent to the guest

```bash
virsh net-list --all
```

If `default` isn't marked active on either host:

```bash
virsh net-start default
virsh net-autostart default
```

This is libvirt's built-in NAT network — it exists identically on both machines out of the box. The VM's traffic is NAT'd behind whichever host is currently running it, at the cost of not being directly reachable from other devices on your LAN — the trade you chose for reliability over bridging. You interact with the VM via its own console locally anyway, so that cost doesn't actually bite you.

To get "looks the same to the software" as close to literal as NAT allows, check both hosts land on the same subnet:
```bash
virsh net-dumpxml default | grep -A1 "<ip "
```
A fresh libvirt install defaults to `192.168.122.0/24` on both machines unless something's been customized — if they already match, skip ahead. If they don't, edit one to match the other (`virsh net-edit default`, then restart the network) before continuing.

With matching subnets, give the guest a **static IP inside the OS itself** once it's installed (Phase 5), rather than relying on DHCP — same address, same gateway, every single time, regardless of which physical host is actually running it. Something like `192.168.122.50/24`, gateway `192.168.122.1`.

**One more thing "looks the same to the software" can mean:** if you also want the guest OS itself unable to tell it's virtualized — no `QEMU`/`KVM` strings showing up in DMI/SMBIOS, no hypervisor CPUID bit — that's a separate, easy change (spoofing SMBIOS strings to match real hardware, hiding the hypervisor leaf) but it's not something any normal application will notice or need. Say the word if that's part of what you're after and I'll add it.

### 1.4 Make sure both hosts use the same kind of libvirt connection

libvirt has two independent connection modes: `qemu:///system` (the privileged, system-wide daemon — persistent networks, standard storage locations, what everything in this guide assumes) and `qemu:///session` (a per-user, unprivileged instance with its own completely separate VM inventory, storage, and networks). They share nothing, even on the same machine.

Check what each host is actually defaulting to:
```bash
virsh uri
```

If either one prints `qemu:///session`, every unprefixed `virsh` command in this guide run on that host is quietly operating against the wrong, empty instance — a different `default` network, a different (probably nonexistent, once you reach Phase 4) `nomad` domain, none of it visible from `qemu:///system`.

You want `qemu:///system` on both. Confirm it actually works there first:
```bash
sudo systemctl enable --now libvirtd
virsh --connect qemu:///system list --all
groups $USER   # should list `libvirt` — if it doesn't, log out and back in; Phase 1.1's group change needs a fresh session to take effect
```

If that connects cleanly, the fix is just making it the *default* instead of session:
```bash
echo 'export LIBVIRT_DEFAULT_URI=qemu:///system' >> ~/.bashrc
source ~/.bashrc
virsh uri   # should now print qemu:///system
```

Do this on whichever host reported session mode — likely the laptop. A fresh desktop-oriented install, or a group membership change that hasn't survived a relogin yet, is the more common place for `virsh` to end up quietly defaulting to a personal session instance instead of the system daemon.

---

## Phase 2 — Compute and verify a portable CPU baseline

This is the step that makes migration between the 8th-gen laptop CPU and the 12th-gen NUC CPU actually safe. Do this *before* creating the VM.

### 2.1 Extract each host's CPU description

On the **NUC**:
```bash
virsh domcapabilities --machine q35 --arch x86_64 --virttype kvm | \
  xmllint --xpath "//cpu/mode[@name='host-model']" - > nuc-cpu-raw.xml
```

On the **laptop**:
```bash
virsh domcapabilities --machine q35 --arch x86_64 --virttype kvm | \
  xmllint --xpath "//cpu/mode[@name='host-model']" - > laptop-cpu-raw.xml
```

Passing `--machine q35 --arch x86_64 --virttype kvm` explicitly matters — without it, each host may query against a different default machine-type version, which muddies the comparison.

### 2.2 Fix up the tags

Each file looks like:
```xml
<mode name="host-model" supported="yes">
  <model fallback="allow">...</model>
  <vendor>Intel</vendor>
  <feature policy="require" name="..."/>
  ...
</mode>
```

Edit both files: change the opening `<mode name="host-model" supported="yes">` to `<cpu>`, and the closing `</mode>` to `</cpu>`. Save as `nuc-cpu.xml` and `laptop-cpu.xml`.

### 2.3 Compute the baseline

Copy both files onto one machine and combine them:
```bash
cat nuc-cpu.xml laptop-cpu.xml > both-cpus.xml
```

```bash
virsh hypervisor-cpu-baseline both-cpus.xml --migratable > baseline-cpu.xml
# older libvirt: virsh cpu-baseline both-cpus.xml --migratable > baseline-cpu.xml
```

`baseline-cpu.xml` now contains a ready-to-use `<cpu mode='custom' match='exact' check='full'>...</cpu>` block — the largest safe common feature set between the two machines. It'll likely land around a Skylake-era feature set with some qualifiers (e.g. `-noTSX-IBRS`), since that's roughly the ceiling the laptop's silicon sets — the NUC supports far more, but the guest can only safely use what both sides guarantee.

*(One footnote for your own peace of mind: Alder Lake's hybrid P+E cores are famous for disabling AVX-512 to keep both core types consistent — but that's moot here, since Kaby Lake R never had AVX-512 to begin with. Nothing hybrid-architecture-specific to worry about beyond the general "older feature set wins" rule above.)*

### 2.4 Verify it — don't just trust the math

```bash
# On both the NUC and the laptop:
virsh hypervisor-cpu-compare baseline-cpu.xml --virttype kvm --arch x86_64 --machine q35
# older libvirt without this command: virsh cpu-compare baseline-cpu.xml
```

Both should report the definition as identical to, or a safe subset of, what that host can provide. Don't proceed to Phase 4 until both pass.

Prefer `hypervisor-cpu-compare`: it asks QEMU/KVM what it can really provide. Plain `cpu-compare` only checks libvirt's static host CPU description and can wrongly report this baseline as incompatible, even though the VM runs with it. (`scripts/03-cpu-baseline.sh verify` does the right one automatically.)

### 2.5 Your computed baseline (validated)

One thing worth flagging in the raw extraction before trusting the output: the NUC's `host-model` reports its base model as `SierraForest` — Intel's all-E-core Xeon line, obviously not what's in a NUC12SNKi7. Not a sign anything's actually wrong: QEMU's `host-model` detection doesn't match on family or marketing name, it walks its built-in CPU model table for the newest named model whose *required feature bits* are fully satisfied by the real CPUID, and there's no dedicated "Alder Lake client" entry in that table (Intel/Red Hat mostly add server Xeon generations, not mobile/desktop ones) — so it lands on whichever named model's feature list happens to fit. Worth a sanity check (`qemu-system-x86_64 --version` on both hosts, confirm `lscpu` on the NUC shows the 12700H) but not something to fix before proceeding — the label is cosmetic, and `cpu-baseline` operates on the underlying feature bits, not the name.

What matters is the feature-level math, and it checks out on manual review:

- **`invtsc` disappeared entirely**, even though both hosts individually require it. That's `--migratable` doing exactly its job — invariant TSC is specifically excluded because guest clock behavior isn't guaranteed consistent across a migration to a host with a different TSC rate. Linux guests under KVM default to `kvmclock` as their timesource anyway, so you won't notice this in practice.
- **`mpx` moved from required (laptop) to explicitly disabled.** The NUC's raw dump doesn't mention it in either direction — Intel dropped MPX starting around Alder Lake, so the NUC genuinely lacks it, and the baseline correctly refuses to promise it to the guest.
- **The long `vmx-*` sublist correctly narrows to the laptop's shorter list.** The NUC's raw dump looks sparse by comparison, but that's just how `host-model` output works — features already implied by the base named model's defaults don't get an explicit line, only deviations do. The tool expands both sides fully before intersecting, so the short NUC list isn't a gap.

Save this as `baseline-cpu.xml` — it goes straight into the domain XML in Phase 4:

```xml
<cpu mode='custom' match='exact'>
  <model fallback='forbid'>Skylake-Client-IBRS</model>
  <vendor>Intel</vendor>
  <maxphysaddr mode='passthrough' limit='39'/>
  <feature policy='require' name='vmx'/>
  <feature policy='require' name='hypervisor'/>
  <feature policy='require' name='ss'/>
  <feature policy='require' name='tsc_adjust'/>
  <feature policy='require' name='zero-fcs-fds'/>
  <feature policy='require' name='clflushopt'/>
  <feature policy='require' name='umip'/>
  <feature policy='require' name='md-clear'/>
  <feature policy='require' name='stibp'/>
  <feature policy='require' name='flush-l1d'/>
  <feature policy='require' name='arch-capabilities'/>
  <feature policy='require' name='ssbd'/>
  <feature policy='require' name='xsaves'/>
  <feature policy='require' name='pdpe1gb'/>
  <feature policy='require' name='ibpb'/>
  <feature policy='require' name='ibrs'/>
  <feature policy='require' name='amd-stibp'/>
  <feature policy='require' name='amd-ssbd'/>
  <feature policy='require' name='skip-l1dfl-vmentry'/>
  <feature policy='require' name='pschange-mc-no'/>
  <feature policy='require' name='gds-no'/>
  <feature policy='require' name='its-no'/>
  <feature policy='require' name='vmx-ins-outs'/>
  <feature policy='require' name='vmx-true-ctls'/>
  <feature policy='require' name='vmx-store-lma'/>
  <feature policy='require' name='vmx-activity-hlt'/>
  <feature policy='require' name='vmx-activity-wait-sipi'/>
  <feature policy='require' name='vmx-vmwrite-vmexit-fields'/>
  <feature policy='require' name='vmx-apicv-xapic'/>
  <feature policy='require' name='vmx-ept'/>
  <feature policy='require' name='vmx-desc-exit'/>
  <feature policy='require' name='vmx-rdtscp-exit'/>
  <feature policy='require' name='vmx-apicv-x2apic'/>
  <feature policy='require' name='vmx-vpid'/>
  <feature policy='require' name='vmx-wbinvd-exit'/>
  <feature policy='require' name='vmx-unrestricted-guest'/>
  <feature policy='require' name='vmx-rdrand-exit'/>
  <feature policy='require' name='vmx-invpcid-exit'/>
  <feature policy='require' name='vmx-vmfunc'/>
  <feature policy='require' name='vmx-shadow-vmcs'/>
  <feature policy='require' name='vmx-rdseed-exit'/>
  <feature policy='require' name='vmx-pml'/>
  <feature policy='require' name='vmx-xsaves'/>
  <feature policy='require' name='vmx-ept-execonly'/>
  <feature policy='require' name='vmx-page-walk-4'/>
  <feature policy='require' name='vmx-ept-2mb'/>
  <feature policy='require' name='vmx-ept-1gb'/>
  <feature policy='require' name='vmx-invept'/>
  <feature policy='require' name='vmx-eptad'/>
  <feature policy='require' name='vmx-invept-single-context'/>
  <feature policy='require' name='vmx-invept-all-context'/>
  <feature policy='require' name='vmx-invvpid'/>
  <feature policy='require' name='vmx-invvpid-single-addr'/>
  <feature policy='require' name='vmx-invvpid-all-context'/>
  <feature policy='require' name='vmx-invvpid-single-context-noglobals'/>
  <feature policy='require' name='vmx-intr-exit'/>
  <feature policy='require' name='vmx-nmi-exit'/>
  <feature policy='require' name='vmx-vnmi'/>
  <feature policy='require' name='vmx-preemption-timer'/>
  <feature policy='require' name='vmx-vintr-pending'/>
  <feature policy='require' name='vmx-tsc-offset'/>
  <feature policy='require' name='vmx-hlt-exit'/>
  <feature policy='require' name='vmx-invlpg-exit'/>
  <feature policy='require' name='vmx-mwait-exit'/>
  <feature policy='require' name='vmx-rdpmc-exit'/>
  <feature policy='require' name='vmx-rdtsc-exit'/>
  <feature policy='require' name='vmx-cr3-load-noexit'/>
  <feature policy='require' name='vmx-cr3-store-noexit'/>
  <feature policy='require' name='vmx-cr8-load-exit'/>
  <feature policy='require' name='vmx-cr8-store-exit'/>
  <feature policy='require' name='vmx-flexpriority'/>
  <feature policy='require' name='vmx-vnmi-pending'/>
  <feature policy='require' name='vmx-movdr-exit'/>
  <feature policy='require' name='vmx-io-exit'/>
  <feature policy='require' name='vmx-io-bitmap'/>
  <feature policy='require' name='vmx-mtf'/>
  <feature policy='require' name='vmx-msr-bitmap'/>
  <feature policy='require' name='vmx-monitor-exit'/>
  <feature policy='require' name='vmx-pause-exit'/>
  <feature policy='require' name='vmx-secondary-ctls'/>
  <feature policy='require' name='vmx-exit-nosave-debugctl'/>
  <feature policy='require' name='vmx-exit-load-perf-global-ctrl'/>
  <feature policy='require' name='vmx-exit-ack-intr'/>
  <feature policy='require' name='vmx-exit-save-pat'/>
  <feature policy='require' name='vmx-exit-load-pat'/>
  <feature policy='require' name='vmx-exit-save-efer'/>
  <feature policy='require' name='vmx-exit-load-efer'/>
  <feature policy='require' name='vmx-exit-save-preemption-timer'/>
  <feature policy='require' name='vmx-entry-noload-debugctl'/>
  <feature policy='require' name='vmx-entry-ia32e-mode'/>
  <feature policy='require' name='vmx-entry-load-perf-global-ctrl'/>
  <feature policy='require' name='vmx-entry-load-pat'/>
  <feature policy='require' name='vmx-entry-load-efer'/>
  <feature policy='require' name='vmx-eptp-switching'/>
  <feature policy='disable' name='hle'/>
  <feature policy='disable' name='rtm'/>
  <feature policy='disable' name='mpx'/>
</cpu>
```

Still run the actual `hypervisor-cpu-compare` check from 2.4 on both real machines before trusting this in production — the analysis above is a strong signal, not a substitute for the tool confirming it against your actual hardware.

---

## Phase 3 — Plan the disk layout

Live migration with non-shared storage has to copy the whole disk. If everything — OS, apps, *and* your project archives, media, ISOs — lives on one big virtual disk, every single handoff re-copies all of it: tens of minutes, every trip, every day. Keep the migrated disk to OS + apps + active working files (aim for well under 60GB actually used) and push bulk data elsewhere.

**Recommended: NFS export from the NUC**, mounted by the guest with options that won't hang the session when unreachable (i.e., when the VM has moved to the laptop and you're away from home):

On the **NUC**:
```bash
sudo apt install nfs-kernel-server
sudo mkdir -p /srv/bulk
sudo chown nobody:nogroup /srv/bulk
echo "/srv/bulk *(rw,sync,no_subtree_check)" | sudo tee -a /etc/exports
sudo exportfs -ra
sudo systemctl enable --now nfs-kernel-server
```
(A wildcard export is fine for a private home LAN; tighten to a specific subnet if that's not your situation.)

Inside the **guest** (add once the VM exists — see Phase 5):
```bash
sudo mkdir -p /mnt/bulk
echo "nuc.local:/srv/bulk /mnt/bulk nfs soft,timeo=30,retrans=2,nofail,_netdev 0 0" | sudo tee -a /etc/fstab
sudo mount -a
```

`soft,nofail` means a missing NUC (laptop away from home) just leaves `/mnt/bulk` empty instead of hanging the session. This works cleanly when the guest is running on the laptop and on the home LAN. If you hit NAT-hairpin weirdness trying to reach it while the guest is running *on the NUC itself* through its own NAT gateway, `virtiofs` (sharing the NUC directory straight into the guest, no network hop at all) sidesteps it entirely for that specific case — ask if you want it built out.

**Alternative:** Syncthing, if you'd rather have bulk data fully duplicated and available offline too, at the cost of needing to fit on both disks.

---

## Phase 4 — Create the VM

```bash
qemu-img create -f qcow2 /var/lib/libvirt/images/nomad.qcow2 60G

virt-install \
  --name nomad \
  --memory 12288 \
  --vcpus 6 \
  --cpu host-model \
  --machine q35 \
  --boot uefi \
  --disk path=/var/lib/libvirt/images/nomad.qcow2,bus=scsi,discard=unmap \
  --controller type=scsi,model=virtio-scsi \
  --network network=default,model=virtio,rom.bar=off \
  --graphics spice \
  --video virtio \
  --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
  --os-variant detect=on,require=on \
  --cdrom /path/to/your-installer.iso
```

Notes:
- `--memory 12288` (12GiB) is comfortably sized against the laptop's confirmed 24GB — leaves plenty for its own desktop environment and QEMU's overhead alongside the guest. You'll be able to use much more while docked at the NUC via ballooning (Phase 8).
- `--vcpus 6` leaves the laptop's 8 logical threads some headroom for its own OS. You'll get more out of the NUC via hotplug (Phase 8).
- `--network network=default,model=virtio,rom.bar=off` attaches to the NAT network from Phase 1.3 — remember to set the guest's static IP once it's installed (also Phase 1.3) so its network identity stays identical regardless of which host it's running on.
- `rom.bar=off` (`<rom bar='off'/>` in the XML) is required for live migration. The virtio-net option ROM is migrated as a RAM block, and distros ship it in different sizes (e.g. 512 KB on Ubuntu, 256 KB on Kali), which makes the destination fail with `Size mismatch: ...virtio-net-pci.rom` and a generic `error while loading state for instance 0x0 of device 'ram'`. The guest never PXE-boots, so nothing is lost.
- `--cpu host-model` here is just a placeholder to get through the install — swapped out for the real baseline (2.5) right after.
- If `--os-variant detect=on,require=on` fails to identify your install media, pass the variant explicitly instead (e.g. `--os-variant ubuntu24.04`).

Once installed, swap in the real CPU baseline:
```bash
virsh shutdown nomad
virsh edit nomad
# Replace the <cpu mode='host-model'/> line with the full contents of baseline-cpu.xml
virsh start nomad
```

---

## Phase 5 — Guest OS setup

Inside the guest:
```bash
sudo apt install qemu-guest-agent   # or dnf/pacman equivalent
sudo systemctl enable --now qemu-guest-agent
```

This gives you clean `virsh shutdown`, IP reporting, and consistent snapshots. Verify from the host:
```bash
virsh domifaddr nomad
```

Now go back and add the `/mnt/bulk` NFS mount from Phase 3 if you're using it.

---

## Phase 6 — Test cold migration first

Don't trust live migration until a manual cold copy has round-tripped cleanly both directions.

```bash
# On the NUC:
virsh shutdown nomad
# wait until `virsh list --all` shows it as "shut off"

virsh dumpxml nomad > nomad.xml
scp nomad.xml you@laptop.local:~/
rsync -avP /var/lib/libvirt/images/nomad.qcow2 you@laptop.local:/var/lib/libvirt/images/

# On the laptop:
virsh define ~/nomad.xml
virsh start nomad
```

Confirm it boots cleanly and everything's intact. Then do the same in reverse to bring it back to the NUC.

---

## Phase 7 — Live migration (the actual handoff)

Once cold migration is proven, this is your daily command. Run it 10–20 minutes before you plan to leave — it copies RAM and disk live while you keep working, with only a brief pause (typically well under a couple seconds for normal desktop use) at the very end.

```bash
# From the NUC, when it's time to head out:
virsh migrate --live --persistent --undefinesource --copy-storage-all \
  nomad qemu+ssh://you@laptop.local/system
```

```bash
# From the laptop, once you're docked again:
virsh migrate --live --persistent --undefinesource --copy-storage-all \
  nomad qemu+ssh://you@nuc.local/system
```

Both directions have been verified working (NUC → laptop and laptop → NUC). The whole disk is copied every time.

**Pin the data connection to IPv4.** By default QEMU connects to whatever the destination's hostname resolves to, IPv6 first. If the destination's firewall drops IPv6 on the migration ports (49152–49215), each attempt waits for the TCP SYN timeout and the migration stalls for minutes (twice, ~9 min each, laptop → NUC) while `virsh domjobinfo` times out and the guest freezes. Add `--migrateuri tcp://<destination IPv4>`; `scripts/migrate.sh` does this automatically. Requirements for it to work: `rom.bar=off` on the NIC (Phase 4) and matching QEMU/machine type.

`--persistent` writes the domain config on the destination; `--undefinesource` removes it from wherever it just left, so the VM's definition always lives wherever the VM currently is.

**Stale disk files:** `--undefinesource` removes the libvirt *config* from the source, not the leftover disk file in `/var/lib/libvirt/images/`. That is fine: `--copy-storage-all` overwrites the stale file on the next migration back (verified on both hosts). `scripts/migrate.sh` only warns about it.

---

## Phase 8 — Performance enhancements (do this *after* Phases 1–7 are solid)

Get the conservative static setup working and trusted first. These add real complexity — layer them on once you trust the basics, not before.

### 8.1 vCPU hotplug

Give the NUC room to actually stretch:
```bash
virsh shutdown nomad
virsh edit nomad
```
Change:
```xml
<vcpu placement='static'>6</vcpu>
```
to:
```xml
<vcpu placement='static' current='6'>16</vcpu>
```
```bash
virsh start nomad
```

Then in daily use:
```bash
virsh setvcpus nomad 16 --live    # once docked at the NUC
virsh setvcpus nomad 6 --live     # before/after heading to the laptop
```

Verify inside the guest with `lscpu | grep "^CPU(s):"` — mainstream systemd distros auto-online hotplugged vCPUs, but confirm it rather than assume.

### 8.2 Memory ballooning

Similarly, let the NUC's much larger RAM actually get used:
```bash
virsh edit nomad
```
```xml
<memory unit='KiB'>41943040</memory>        <!-- 40 GiB max -->
<currentMemory unit='KiB'>12582912</currentMemory>   <!-- 12 GiB active, matches Phase 4 -->
```

```bash
virsh setmem nomad 40G --live     # inflate while at the NUC — confirmed 64GB installed, leaves plenty for the host
virsh setmem nomad 12G --live     # deflate with some idle buffer before migrating to the laptop
```

Caveat: the balloon can only reclaim memory the guest voluntarily releases. Deflate with a few minutes of breathing room before a migration, not seconds before, and expect it to behave worse if you deflate right after heavy memory use.

### 8.3 (Optional, fiddlier) 3D-accelerated graphics

If plain virtio-gpu feels sluggish and it bothers you enough to troubleshoot driver/mesa versions, `accel3d` + SPICE with GL enabled (virgl) hardware-accelerates OpenGL through whichever host's GPU is currently running the VM. Get everything else solid first.

---

## Quick troubleshooting checklist

- **`virsh` permission denied despite `libvirt` group membership** → check polkit rules for your distro, don't just reach for `sudo`.
- **Migration fails on CPU compatibility** → re-run `virsh hypervisor-cpu-compare` (see 2.4) on both hosts; something in Phase 2 wasn't verified.
- **Guest hangs when `/mnt/bulk` is unreachable** → double-check the `soft,nofail` mount options actually made it into `/etc/fstab`.
- **vCPUs don't come online after `setvcpus`** → check `dmesg` in the guest for hotplug-related messages; some minimal/hardened images need an explicit udev rule to auto-online new CPUs.
- **Live migration fails with `error while loading state for instance 0x0 of device 'ram' ... ret: -22`** → this is a generic wrapper. Read `/var/log/libvirt/qemu/nomad.log` on the *destination* for the real cause. Known one: `Size mismatch: ...virtio-net-pci.rom` — add `<rom bar='off'/>` to the NIC (Phase 4), with the guest shut down, on whichever host defines the domain. Matching QEMU versions and machine types alone did not fix it.
- **`Security driver model 'apparmor' is not available`** → see `FIX-apparmor-migration.md`.
- **`TSC frequency mismatch ... TSC scaling unavailable` in the log** → expected when migrating to the laptop; the baseline drops `invtsc` so the guest uses `kvm-clock`. Verify with `cat /sys/devices/system/clocksource/clocksource0/current_clocksource` in the guest.
- **Migration stalls for minutes, `virsh domjobinfo` times out, guest freezes** → check `ss -tin` on the source for `SYN-SENT` connections to the destination on ports 49152+, usually IPv6. Pin IPv4 with `--migrateuri tcp://<destination IPv4>` (Phase 7).
- **Second live migration onward fails or behaves oddly with the disk** → check what's actually sitting at the destination path (Phase 7). A stale file from an earlier migration is normally overwritten without problems.
- **`virsh` commands don't show the VM or network you expect** → check `virsh uri`. If it prints `qemu:///session` instead of `qemu:///system`, you're quietly talking to the wrong libvirt instance — see Phase 1.4.
