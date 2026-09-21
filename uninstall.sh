#!/usr/bin/env bash
# Stops and removes the Onshape -> Bambu Studio bridge.
# Standalone-safe: curl -fsSL <raw-url>/uninstall.sh | bash works too, it
# only touches already-installed paths, no repo checkout needed.
set -euo pipefail

APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/onshape-bambu-bridge"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/onshape-bambu-bridge"
UNIT_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/onshape-bambu-bridge.service"

log() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# See install.sh for why: a piped `curl ... | bash` consumes stdin as the
# script itself, so the prompt below reads from /dev/tty instead.
: </dev/tty 2>/dev/null || die "This needs an interactive terminal (it asks whether to keep your config). Download it and run it directly: curl -fsSL https://raw.githubusercontent.com/marijn070/onshape-bambu-bridge/main/uninstall.sh -o /tmp/onshape-bambu-uninstall.sh && bash /tmp/onshape-bambu-uninstall.sh"

if [ -f "$UNIT_PATH" ]; then
    log "Stopping and disabling the systemd service"
    systemctl --user disable --now onshape-bambu-bridge.service || true
    rm -f "$UNIT_PATH"
    systemctl --user daemon-reload
fi

log "Removing $APP_DIR"
rm -rf "$APP_DIR"

read -r -p "Also delete config (Onshape API key) at $CONFIG_DIR? [y/N] " ANSWER </dev/tty
if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR"
    log "Removed $CONFIG_DIR"
else
    log "Kept $CONFIG_DIR"
fi

echo "Done. Don't forget to remove the Tampermonkey userscript if you no longer want it."
