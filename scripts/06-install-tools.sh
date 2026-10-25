#!/usr/bin/env bash
# Installs the `nomad` command on this host: symlink in ~/.local/bin and config in ~/.config/nomad/config.
# Run it on BOTH hosts. Safe to re-run; existing values are offered as defaults.
# Usage: 06-install-tools.sh [--role strong|weak] [--routes "alias1 alias2"] [--auto-inflate|--no-auto-inflate]
#                            [--non-interactive]
#   --routes   ssh aliases (from ~/.ssh/config) that reach the OTHER host, best first: ethernet, then wifi, ...
#   --role     strong = the NUC (inflates, never deflated for the laptop's sake), weak = the laptop
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG="${NOMAD_CONFIG:-$HOME/.config/nomad/config}"
ROLE="" ROUTES="" AUTO_INFLATE=""
[ ! -r "$CONFIG" ] || source "$CONFIG"
INTERACTIVE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:?}"; shift ;;
    --routes) ROUTES="${2:?}"; shift ;;
    --auto-inflate) AUTO_INFLATE=1 ;;
    --no-auto-inflate) AUTO_INFLATE=0 ;;
    --non-interactive) INTERACTIVE=0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

ask() { # ask <varname> <prompt>: keeps the current value when the answer is empty
  local var="$1" cur="${!1}" a=""
  [ "$INTERACTIVE" = 1 ] || return 0
  read -r -p "$2${cur:+ [$cur]}: " a || true
  printf -v "$var" '%s' "${a:-$cur}"
}

[ -n "$ROLE" ] || { [ "$(nproc)" -ge 16 ] && ROLE=strong || ROLE=weak; }
ask ROLE "Is this host the strong one (NUC) or the weak one (laptop)? (strong/weak)"
[ "$ROLE" = strong ] || [ "$ROLE" = weak ] || die "role must be 'strong' or 'weak'"
ask ROUTES "ssh aliases that reach the OTHER host, best first (e.g. 'laptop-eth laptop-wifi')"
[ -n "$ROUTES" ] || die "at least one ssh alias is needed"
[ -n "$AUTO_INFLATE" ] || AUTO_INFLATE=1
if [ "$INTERACTIVE" = 1 ]; then
  a=""
  read -r -p "Inflate the VM automatically after migrating to the strong host? (y/n) [$([ "$AUTO_INFLATE" = 1 ] && echo y || echo n)]: " a || true
  case "$a" in [Yy]*) AUTO_INFLATE=1 ;; [Nn]*) AUTO_INFLATE=0 ;; esac
fi

for r in $ROUTES; do
  if ssh -o BatchMode=yes -o ConnectTimeout=3 "$r" true 2>/dev/null; then log "ssh $r: ok"
  else warn "ssh $r failed (needs key login, guide Phase 1.2); keeping it in the list anyway"; fi
done

mkdir -p "$(dirname "$CONFIG")" "$HOME/.local/bin"
{
  echo "# written by scripts/06-install-tools.sh"
  echo "ROLE=$ROLE"
  echo "ROUTES=\"$ROUTES\""
  echo "AUTO_INFLATE=$AUTO_INFLATE"
  echo "STALL_SECS=${STALL_SECS:-60}"
} > "$CONFIG"
ln -sfn "$SCRIPT_DIR/nomad" "$HOME/.local/bin/nomad"
chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/nomad"
log "Wrote $CONFIG and linked ~/.local/bin/nomad -> $SCRIPT_DIR/nomad"

command -v notify-send >/dev/null 2>&1 || warn "notify-send not found; stall alerts will only ring the terminal bell (apt install libnotify-bin)"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "~/.local/bin is not in PATH: bash: export PATH=\"\$HOME/.local/bin:\$PATH\"   fish: fish_add_path ~/.local/bin" ;;
esac
log "Try: nomad status"
