#!/usr/bin/env bash
# Interactive installer for the Onshape -> Bambu Studio bridge (Linux).
#
# - Creates a venv under ~/.local/share/onshape-bambu-bridge and installs deps
# - Prompts for your Onshape API key pair
# - Detects how to launch Bambu Studio (Flatpak / AppImage / native binary)
# - Writes ~/.config/onshape-bambu-bridge/config.json (chmod 600)
# - Runs a smoke test against the Onshape API
# - Installs and starts a systemd --user service
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/onshape-bambu-bridge"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/onshape-bambu-bridge"
CONFIG_PATH="$CONFIG_DIR/config.json"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_PATH="$SYSTEMD_USER_DIR/onshape-bambu-bridge.service"
VENV_DIR="$APP_DIR/.venv"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------- 1. Python ----------
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH."
PY_OK=$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 10) else 0)')
[ "$PY_OK" = "1" ] || die "Python 3.10+ required, found $(python3 --version)."
log "Using $(python3 --version)"

# ---------- 2. App dir + venv ----------
log "Setting up $APP_DIR"
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/server"
cp -a "$REPO_DIR/server" "$APP_DIR/server"

if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtualenv"
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet -r "$APP_DIR/server/requirements.txt"

# ---------- 3. Onshape API key ----------
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

EXISTING_ACCESS=""
EXISTING_SECRET=""
if [ -f "$CONFIG_PATH" ]; then
    EXISTING_ACCESS=$(python3 -c "import json;print(json.load(open('$CONFIG_PATH')).get('onshape_access_key',''))" 2>/dev/null || true)
    EXISTING_SECRET=$(python3 -c "import json;print(json.load(open('$CONFIG_PATH')).get('onshape_secret_key',''))" 2>/dev/null || true)
fi

echo
echo "Get an Onshape API key pair at https://dev-portal.onshape.com -> API keys -> Create new API key"
echo "(read access is enough; the secret is shown only once)."
echo

read -r -p "Onshape access key${EXISTING_ACCESS:+ [press enter to keep existing]}: " ACCESS_KEY
ACCESS_KEY="${ACCESS_KEY:-$EXISTING_ACCESS}"
[ -n "$ACCESS_KEY" ] || die "Access key is required."

read -r -s -p "Onshape secret key${EXISTING_SECRET:+ [press enter to keep existing]}: " SECRET_KEY
echo
SECRET_KEY="${SECRET_KEY:-$EXISTING_SECRET}"
[ -n "$SECRET_KEY" ] || die "Secret key is required."

# ---------- 4. Detect Bambu Studio ----------
BAMBU_CMD_JSON=""

if command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -q com.bambulab.BambuStudio; then
    log "Found Bambu Studio via Flatpak."
    BAMBU_CMD_JSON='["flatpak", "run", "com.bambulab.BambuStudio"]'
elif command -v bambu-studio >/dev/null 2>&1; then
    P=$(command -v bambu-studio)
    log "Found Bambu Studio on PATH: $P"
    BAMBU_CMD_JSON="[\"$P\"]"
elif command -v BambuStudio >/dev/null 2>&1; then
    P=$(command -v BambuStudio)
    log "Found Bambu Studio on PATH: $P"
    BAMBU_CMD_JSON="[\"$P\"]"
else
    CANDIDATE=$(find "$HOME/Applications" "$HOME/.local/bin" "$HOME/Downloads" -maxdepth 2 \
        -iname '*bambu*studio*.AppImage' 2>/dev/null | head -n1 || true)
    if [ -n "$CANDIDATE" ]; then
        chmod +x "$CANDIDATE"
        log "Found Bambu Studio AppImage: $CANDIDATE"
        BAMBU_CMD_JSON="[\"$CANDIDATE\"]"
    fi
fi

if [ -z "$BAMBU_CMD_JSON" ]; then
    warn "Could not auto-detect Bambu Studio."
    read -r -p "Enter the full path to the Bambu Studio executable or AppImage: " MANUAL_PATH
    [ -x "$MANUAL_PATH" ] || die "$MANUAL_PATH is not an executable file."
    BAMBU_CMD_JSON="[\"$MANUAL_PATH\"]"
fi

# ---------- 5. Export format / dir ----------
read -r -p "Export format, 3MF or STL [3MF]: " EXPORT_FORMAT
EXPORT_FORMAT="${EXPORT_FORMAT:-3MF}"
read -r -p "Export directory [~/OnshapeExports]: " EXPORT_DIR
EXPORT_DIR="${EXPORT_DIR:-$HOME/OnshapeExports}"
read -r -p "Local port [7777]: " PORT
PORT="${PORT:-7777}"

# ---------- 6. Write config.json ----------
python3 - "$CONFIG_PATH" "$ACCESS_KEY" "$SECRET_KEY" "$EXPORT_DIR" "$EXPORT_FORMAT" "$PORT" "$BAMBU_CMD_JSON" <<'PY'
import json, sys
path, access, secret, export_dir, export_format, port, bambu_cmd_json = sys.argv[1:8]
cfg = {
    "onshape_access_key": access,
    "onshape_secret_key": secret,
    "onshape_base_url": "https://cad.onshape.com",
    "bambu_studio_cmd": json.loads(bambu_cmd_json),
    "export_dir": export_dir,
    "export_format": export_format.upper(),
    "port": int(port),
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
chmod 600 "$CONFIG_PATH"
log "Wrote $CONFIG_PATH (chmod 600)"

# ---------- 7. Smoke test ----------
log "Checking Onshape credentials..."
"$VENV_DIR/bin/python" "$APP_DIR/server/smoke_test.py" || die "Smoke test failed. Re-run this installer to fix your API key."

# ---------- 8. systemd --user service ----------
mkdir -p "$SYSTEMD_USER_DIR"
cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Onshape -> Bambu Studio bridge
After=network.target graphical-session.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python $APP_DIR/server/main.py
Restart=on-failure
RestartSec=2
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now onshape-bambu-bridge.service

sleep 1
if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    log "Bridge is running: http://127.0.0.1:$PORT/health"
else
    warn "Bridge did not respond on port $PORT. Check: journalctl --user -u onshape-bambu-bridge -e"
fi

echo
log "Install complete. Next step: install the Tampermonkey userscript."
echo "  1. Install the Tampermonkey extension in your browser."
echo "  2. Open $REPO_DIR/userscript/onshape-bambu.user.js, copy its contents."
echo "  3. Tampermonkey icon -> Create a new script -> paste -> Ctrl+S."
echo "  4. Open any Part Studio at cad.onshape.com, click 'Send to Bambu'."
echo
echo "Manage the service with:"
echo "  systemctl --user status onshape-bambu-bridge"
echo "  journalctl --user -u onshape-bambu-bridge -f"
