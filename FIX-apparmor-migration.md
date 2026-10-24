# Fix: `Security driver model 'apparmor' is not available` on live migration

## Symptom

`virsh migrate` from the NUC fails right away:

```
error: unsupported configuration: Security driver model 'apparmor' is not available
```

## Cause

The domain on the NUC carries an AppArmor `<seclabel>`. The destination (laptop, Kali) only reports the `none` and `dac` security models, so it rejects the label.

On the laptop the AppArmor kernel module is enabled and libvirt's profiles are installed, but `apparmor.service` is **disabled**. Nothing loads libvirt's profiles at boot, so libvirtd starts without its AppArmor driver.

## Diagnose (on the destination host)

```bash
virsh capabilities | grep -A3 '<secmodel>'      # apparmor missing = this problem
cat /sys/module/apparmor/parameters/enabled     # Y = kernel is fine
sudo aa-status | head -8                        # only docker-default = profiles not loaded
systemctl status apparmor --no-pager | head -5  # disabled/inactive = root cause
ls /etc/apparmor.d/libvirt/TEMPLATE.qemu /etc/apparmor.d/usr.sbin.libvirtd
```

If `enabled` is not `Y`, add `apparmor=1 security=apparmor` to `GRUB_CMDLINE_LINUX_DEFAULT`, run `sudo update-grub` and reboot. That was not needed on the laptop.

## Fix (on the destination host)

```bash
# Preview what the service will load (loads nothing)
ls /etc/apparmor.d/
sudo apparmor_parser -QN /etc/apparmor.d/ 2>&1 | head -30

# Load libvirt's profiles now
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.libvirtd
sudo apparmor_parser -r /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper

# libvirt picks its security drivers only at startup
sudo systemctl restart libvirtd
virsh capabilities | grep -A3 '<secmodel>'      # should now list apparmor

# Persist across reboots
sudo systemctl enable --now apparmor
sudo aa-status | head -8                        # libvirtd, virt-aa-helper listed
```

If a profile that is not libvirt's breaks something, put it in log-only mode with `sudo aa-complain /etc/apparmor.d/<profile>`. Stopping `apparmor.service` unloads all profiles, so shut the VM down first.

## Workaround without changing the destination

Strip the AppArmor label for a single migration. The source keeps its confinement.

```bash
virsh dumpxml --migratable nomad \
  | xmlstarlet ed -d "/domain/seclabel[@model='apparmor']" > /tmp/nomad-migrate.xml

virsh migrate --live --persistent --undefinesource --copy-storage-all \
  --xml /tmp/nomad-migrate.xml nomad qemu+ssh://you@laptop.local/system
```

Setting `security_driver = "none"` in `/etc/libvirt/qemu.conf` also works but turns off VM confinement on that host, so avoid it.

## Notes

- This error occurs before the RAM state transfer. If migration then fails with `error while loading state for instance 0x0 of device 'ram'`, that is a separate problem (see `handoff-nomad-live-migration-debug.md`).
- Going laptop → NUC needs no workaround: the NUC has AppArmor.
