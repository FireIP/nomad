# Fix: laptop → NUC migration stalls for ~9 minutes (IPv6)

## Symptoms
- Live migration laptop → NUC took ~20 min; NUC → laptop took 3–5 min over the same cable.
- Two dead windows of ~9 min each (before the disk copy and before the RAM phase) with no network traffic.
- `virsh domjobinfo nomad` timed out ("cannot acquire state change lock") and the guest froze during them.
- The actual transfer ran at Gigabit line rate; the NUC and the laptop's disk, memory and swap were not the limit.

## Cause
QEMU connects to whatever the destination's hostname resolves to, and IPv6 is tried first. The NUC's IPv6 addresses (ULA and global) did not answer on the migration ports (49152+), most likely because its firewall only allows them on IPv4 (unverified). QEMU tries addresses one at a time, and each waits for the TCP SYN timeout before falling back to IPv4.

Seen on the source with `scripts/migrate.sh nuc --monitor=3`: a `SYN-SENT` socket to the destination's IPv6 address on port 49152/49153 with a growing retransmit timer.

## Fix
Pin the data connection to the destination's IPv4 address:

```bash
virsh migrate --live --persistent --undefinesource --copy-storage-all \
  --migrateuri tcp://<destination IPv4> nomad qemu+ssh://you@nuc.local/system
```

`scripts/migrate.sh` resolves the peer's IPv4 address and adds this automatically (unless `--migrateuri` is already in `MIGRATE_ARGS`). Verified: the stall is gone.

## Diagnosing
- `scripts/migrate.sh <peer> --monitor=3` logs the migration sockets every few seconds.
- By hand, on the source during a stall: `ss -tin | grep -A1 ':49'`.
- Alternative fix not applied: allow TCP 49152–49215 over IPv6 on the destination's firewall.
