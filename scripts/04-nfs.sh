#!/usr/bin/env bash
# OPTIONAL, guide Phase 3: NFS export for bulk data, so the migrated disk stays small.
# Not run by any other script; nothing else depends on it.
# Usage:
#   04-nfs.sh server [dir]    on the NUC: install the NFS server and export dir (default /srv/bulk)
#   04-nfs.sh fstab [dir]     prints the line for the guest's /etc/fstab (does not edit anything)
# Env: NFS_CLIENTS (default '*', fine for a private LAN; use e.g. 192.168.122.0/24 to tighten),
#      NFS_HOST (default nuc.local, used by 'fstab').
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd="${1:-}"
dir="${2:-/srv/bulk}"
clients="${NFS_CLIENTS:-*}"

case "$cmd" in
  server)
    case "$(pkg_mgr)" in
      apt-get) sudo apt-get install -y nfs-kernel-server; svc=nfs-kernel-server ;;
      dnf)     sudo dnf install -y nfs-utils; svc=nfs-server ;;
      pacman)  sudo pacman -S --needed --noconfirm nfs-utils; svc=nfs-server ;;
    esac
    sudo mkdir -p "$dir"
    sudo chown nobody:"$(getent group nogroup >/dev/null && echo nogroup || echo nobody)" "$dir"
    export_line="$dir $clients(rw,sync,no_subtree_check)"
    if ! grep -qxF "$export_line" /etc/exports 2>/dev/null; then
      log "Adding export: $export_line"
      echo "$export_line" | sudo tee -a /etc/exports >/dev/null
    fi
    sudo exportfs -ra
    sudo systemctl enable --now "$svc"
    log "Exported $dir"
    ;;
  fstab)
    echo "${NFS_HOST:-nuc.local}:$dir /mnt/bulk nfs soft,timeo=30,retrans=2,nofail,_netdev 0 0"
    echo "# in the guest: sudo mkdir -p /mnt/bulk, append the line above to /etc/fstab, sudo mount -a"
    ;;
  *)
    die "usage: $0 server [dir] | fstab [dir]"
    ;;
esac
