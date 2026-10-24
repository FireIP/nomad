#!/usr/bin/env bash
# Guide Phase 1.1 + 1.4: install virtualization packages, group membership,
# libvirtd, and make qemu:///system the default URI. Idempotent; run on both hosts.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "$(id -u)" -ne 0 ] || die "run as your normal user; the script uses sudo where needed"

case "$(pkg_mgr)" in
  apt-get)
    log "Installing packages (apt)"
    sudo apt-get install -y qemu-system-x86 libvirt-daemon-system libvirt-clients \
      virtinst virt-manager ovmf swtpm libxml2-utils python3
    ;;
  dnf)
    log "Installing packages (dnf)"
    sudo dnf install -y @virtualization swtpm libxml2 python3
    ;;
  pacman)
    log "Installing packages (pacman)"
    sudo pacman -S --needed --noconfirm qemu-full libvirt virt-install virt-manager \
      edk2-ovmf swtpm dnsmasq libxml2 python
    ;;
esac

for g in libvirt kvm; do
  if getent group "$g" >/dev/null && ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then
    log "Adding $USER to group $g (log out and back in afterwards)"
    sudo usermod -aG "$g" "$USER"
  fi
done

log "Enabling libvirtd"
sudo systemctl enable --now libvirtd 2>/dev/null || sudo systemctl enable --now libvirtd.socket

line='export LIBVIRT_DEFAULT_URI=qemu:///system'
if ! grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null; then
  log "Adding LIBVIRT_DEFAULT_URI to ~/.bashrc"
  echo "$line" >> "$HOME/.bashrc"
fi

log "Done. If group membership changed, log out and back in, then run scripts/00-preflight.sh"
