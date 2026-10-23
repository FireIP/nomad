# NUC ↔ Laptop Workstation Handoff — Build Guide

**Goal:** A single Linux VM ("the workstation") that lives on the NUC's fast storage while you're docked at home, and migrates over to the laptop — live, with open apps intact — when it's time to leave. Neither machine gets reinstalled; both keep their normal host OS with libvirt/QEMU/KVM layered on top.

**Machines:**
- NUC12SNKi72 ("nuc") — i7-12700H, 14c/20t, up to 64GB DDR4-3200, 2.5GbE — the workhorse.
- Fujitsu Lifebook S938 ("laptop") — 8th-gen Kaby Lake R (i5/i7-8xxxU), 4c/8t, Gigabit Ethernet — the portable endpoint.

---

## What to actually expect

Read this before you start, so nothing here is a surprise mid-build:

- **CPU/RAM/disk performance really will be much better docked at the NUC.** That gap is real and substantial.
- **Graphics performance will *not* improve at the NUC**, at least not initially. The VM uses virtual graphics (virtio-gpu, no 3D acceleration) so it can migrate at all — compositing, video, anything GPU-bound will feel similar on both hosts regardless of which one is actually running it. 3D acceleration (virgl) is possible later as an add-on, but it's not part of the base build.
- **The first live migration will be slow-ish** because the whole disk has to copy once. Subsequent ones are fast if you keep the migrated disk lean (see Phase 3) — a few minutes, not tens of minutes.
- **This only works when both machines are up and reachable on the same network at the moment you migrate.** It's a "you're home, about to leave" tool, not something that helps while the laptop is already out and about.
- **Bulk data (large files, archives, media) should live outside the migrated disk.** More in Phase 3.

---

## Phase 0 — Before you start

**Check the laptop's actual installed RAM.** Specs for the S938 disagree across sources (16GB / 20GB / one real-world unit at 24GB) — don't trust a spec sheet, check the actual machine:

```bash
free -h
sudo dmidecode -t memory | grep -E "Size|Speed|Locator"
```

Note the total. You'll size the VM's baseline memory comfortably below it (leave several GB for the laptop's own desktop environment + QEMU overhead).

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

### 1.2 SSH keys, both directions

Migration rides over `qemu+ssh://`, which tunnels the whole data stream — no extra ports to open, no separate TLS setup.

```bash
ssh-keygen -t ed25519          # skip if you already have a key
ssh-copy-id you@laptop.local   # run from the NUC
ssh-copy-id you@nuc.local      # run from the laptop
```

Confirm both directions connect with zero prompts before moving on. If `virsh` throws permission errors later despite being in the `libvirt` group, check that libvirt's bundled polkit rules are active for your distro before reaching for `sudo` everywhere — that's the usual culprit.

### 1.3 Confirm the default network is active

```bash
virsh net-list --all
```

If `default` isn't marked active on either host:

```bash
virsh net-start default
virsh net-autostart default
```

We're using libvirt's built-in NAT network (`default`) rather than a bridge — it exists identically on both machines out of the box, and since you'll interact with the VM via its own console locally (not remotely over the LAN), NAT is sufficient. If you later want the VM directly reachable from other devices on your home network, a bridge on the NUC is the upgrade path — ask if you want that built out.

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
# On the NUC:
virsh cpu-compare baseline-cpu.xml

# On the laptop:
virsh cpu-compare baseline-cpu.xml
# (or hypervisor-cpu-compare, depending on libvirt version)
```

Both should report the definition as identical to, or a safe subset of, what that host can provide. Don't proceed to Phase 4 until both pass.

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

`soft,nofail` means a missing NUC (laptop away from home) just leaves `/mnt/bulk` empty instead of hanging the session. This works cleanly when the guest is running on the laptop and on the home LAN. If you hit NAT-hairpin weirdness trying to reach it while the guest is running *on the NUC itself* through its own NAT gateway, the fix is either a bridged network for the guest or a `virtiofs` share of the NUC directory straight into the guest (no network hop at all) — ask if you land there.

**Alternative:** Syncthing, if you'd rather have bulk data fully duplicated and available offline too, at the cost of needing to fit on both disks.

---

## Phase 4 — Create the VM

```bash
qemu-img create -f qcow2 /var/lib/libvirt/images/nomad.qcow2 60G

virt-install \
  --name nomad \
  --memory 8192 \
  --vcpus 6 \
  --cpu host-model \
  --machine q35 \
  --boot uefi \
  --disk path=/var/lib/libvirt/images/nomad.qcow2,bus=scsi,discard=unmap \
  --controller type=scsi,model=virtio-scsi \
  --network network=default,model=virtio \
  --graphics spice \
  --video virtio \
  --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
  --os-variant detect=on,require=on \
  --cdrom /path/to/your-installer.iso
```

Notes:
- `--memory 8192` (8GiB) is a conservative starting point — adjust based on what Phase 0 told you about the laptop's actual installed RAM, staying comfortably below it. You'll be able to use much more while docked at the NUC via ballooning (Phase 8).
- `--vcpus 6` leaves the laptop's 8 logical threads some headroom for its own OS. You'll get more out of the NUC via hotplug (Phase 8).
- `--cpu host-model` here is just a placeholder to get through the install — swapped out next.
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

`--persistent` writes the domain config on the destination; `--undefinesource` removes it from wherever it just left, so the VM's definition always lives wherever the VM currently is.

**One thing to specifically test on your third migration** (the first "back home" leg): `--undefinesource` removes the libvirt *config* from the source, not the leftover disk file sitting in `/var/lib/libvirt/images/`. Whether `--copy-storage-all` cleanly overwrites that stale file or errors against it isn't something to assume — watch it happen once, and clean up manually if needed.

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
<memory unit='KiB'>25165824</memory>        <!-- 24 GiB max -->
<currentMemory unit='KiB'>8388608</currentMemory>   <!-- 8 GiB active, matches Phase 4 -->
```

```bash
virsh setmem nomad 24G --live     # inflate while at the NUC
virsh setmem nomad 8G --live      # deflate with some idle buffer before migrating to the laptop
```

Caveat: the balloon can only reclaim memory the guest voluntarily releases. Deflate with a few minutes of breathing room before a migration, not seconds before, and expect it to behave worse if you deflate right after heavy memory use.

### 8.3 (Optional, fiddlier) 3D-accelerated graphics

If plain virtio-gpu feels sluggish and it bothers you enough to troubleshoot driver/mesa versions, `accel3d` + SPICE with GL enabled (virgl) hardware-accelerates OpenGL through whichever host's GPU is currently running the VM. Get everything else solid first.

---

## Quick troubleshooting checklist

- **`virsh` permission denied despite `libvirt` group membership** → check polkit rules for your distro, don't just reach for `sudo`.
- **Migration fails on CPU compatibility** → re-run `virsh cpu-compare` on both hosts; something in Phase 2 wasn't verified.
- **Guest hangs when `/mnt/bulk` is unreachable** → double-check the `soft,nofail` mount options actually made it into `/etc/fstab`.
- **vCPUs don't come online after `setvcpus`** → check `dmesg` in the guest for hotplug-related messages; some minimal/hardened images need an explicit udev rule to auto-online new CPUs.
- **Second live migration onward fails or behaves oddly with the disk** → this is the stale-file scenario from Phase 7 — check what's actually sitting at the destination path before assuming.
