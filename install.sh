#!/usr/bin/env bash
# Installer for the Onshape -> Bambu Studio bridge (Linux).
#
# Works two ways:
#   - From a local checkout: ./install.sh (uses the server/ files next to it)
#   - Standalone: curl -fsSL <raw-url>/install.sh | bash (downloads the two
#     server files it needs straight from GitHub - no git clone required)
#
# Either way it:
# - Makes sure uv is available (offers to install it if not)
# - Prompts for your Onshape API key pair
# - Detects how to launch Bambu Studio (Flatpak / AppImage / native binary)
# - Writes ~/.config/onshape-bambu-bridge/config.json (chmod 600)
# - Runs a smoke test against the Onshape API
# - Installs and starts a systemd --user service that runs the bridge via
#   `uv run --script` (deps are declared inline in server/main.py, no venv
#   to create or maintain)
# - Offers to open the Tampermonkey + userscript install pages in your browser
set -euo pipefail

GITHUB_RAW_BASE="https://raw.githubusercontent.com/marijn070/onshape-bambu-bridge/main"

# Only set when actually run as a file (./install.sh, bash install.sh) - a
# piped `curl ... | bash` has no real BASH_SOURCE, which is how we tell the
# two install modes apart.
REPO_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/onshape-bambu-bridge"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/onshape-bambu-bridge"
CONFIG_PATH="$CONFIG_DIR/config.json"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_PATH="$SYSTEMD_USER_DIR/onshape-bambu-bridge.service"

USERSCRIPT_RAW_URL="https://raw.githubusercontent.com/marijn070/onshape-bambu-bridge/main/userscript/onshape-bambu.user.js"
TAMPERMONKEY_CHROME_URL="https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo"
TAMPERMONKEY_FIREFOX_URL="https://addons.mozilla.org/en-US/firefox/addon/tampermonkey/"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# This installer prompts for several things (API key, Bambu Studio path,
# export format...). When run as `curl ... | bash`, bash consumes stdin as
# the script source itself, so every prompt below reads from /dev/tty
# instead - that only works with a real terminal behind it.
: </dev/tty 2>/dev/null || die "This installer needs an interactive terminal (it prompts for your Onshape API key, Bambu Studio path, etc). Download it and run it directly instead: curl -fsSL $GITHUB_RAW_BASE/install.sh -o /tmp/onshape-bambu-install.sh && bash /tmp/onshape-bambu-install.sh"

# ---------- 1. uv ----------
if ! command -v uv >/dev/null 2>&1; then
    warn "uv (https://docs.astral.sh/uv/) is not installed. The bridge uses it to run" \
         "server/main.py with its dependencies declared inline, no venv needed."
    read -r -p "Install uv now via the official installer (curl -LsSf https://astral.sh/uv/install.sh | sh)? [y/N] " INSTALL_UV </dev/tty
    if [[ "$INSTALL_UV" =~ ^[Yy]$ ]]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi
command -v uv >/dev/null 2>&1 || die "uv is required. Install it from https://docs.astral.sh/uv/getting-started/installation/ and re-run this installer."
UV_BIN="$(command -v uv)"
log "Using $($UV_BIN --version) at $UV_BIN"

# ---------- 2. App dir ----------
log "Setting up $APP_DIR"
rm -rf "$APP_DIR/server"
mkdir -p "$APP_DIR/server"
if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/server/main.py" ]; then
    log "Installing server files from local checkout ($REPO_DIR)"
    cp "$REPO_DIR/server/main.py" "$REPO_DIR/server/smoke_test.py" "$APP_DIR/server/"
else
    log "Downloading server files from $GITHUB_RAW_BASE"
    curl -fsSL "$GITHUB_RAW_BASE/server/main.py" -o "$APP_DIR/server/main.py"
    curl -fsSL "$GITHUB_RAW_BASE/server/smoke_test.py" -o "$APP_DIR/server/smoke_test.py"
fi
chmod +x "$APP_DIR/server/main.py" "$APP_DIR/server/smoke_test.py"

# ---------- 3. Onshape API key ----------
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

EXISTING_ACCESS=""
EXISTING_SECRET=""
if [ -f "$CONFIG_PATH" ]; then
    EXISTING_ACCESS=$("$UV_BIN" run python -c "import json;print(json.load(open('$CONFIG_PATH')).get('onshape_access_key',''))" 2>/dev/null || true)
    EXISTING_SECRET=$("$UV_BIN" run python -c "import json;print(json.load(open('$CONFIG_PATH')).get('onshape_secret_key',''))" 2>/dev/null || true)
fi

echo
echo "Get an Onshape API key pair at https://cad.onshape.com/user/developer -> API keys -> Create new API key"
echo "(read access is enough; the secret is shown only once)."
echo

read -r -p "Onshape access key${EXISTING_ACCESS:+ [press enter to keep existing]}: " ACCESS_KEY </dev/tty
ACCESS_KEY="${ACCESS_KEY:-$EXISTING_ACCESS}"
[ -n "$ACCESS_KEY" ] || die "Access key is required."

read -r -s -p "Onshape secret key${EXISTING_SECRET:+ [press enter to keep existing]}: " SECRET_KEY </dev/tty
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
    read -r -p "Enter the full path to the Bambu Studio executable or AppImage: " MANUAL_PATH </dev/tty
    [ -x "$MANUAL_PATH" ] || die "$MANUAL_PATH is not an executable file."
    BAMBU_CMD_JSON="[\"$MANUAL_PATH\"]"
fi

# ---------- 5. Export format / dir ----------
read -r -p "Export format, 3MF or STL [3MF]: " EXPORT_FORMAT </dev/tty
EXPORT_FORMAT="${EXPORT_FORMAT:-3MF}"
read -r -p "Export directory [~/OnshapeExports]: " EXPORT_DIR </dev/tty
EXPORT_DIR="${EXPORT_DIR:-$HOME/OnshapeExports}"
read -r -p "Local port [7777]: " PORT </dev/tty
PORT="${PORT:-7777}"

# ---------- 6. Write config.json ----------
"$UV_BIN" run python - "$CONFIG_PATH" "$ACCESS_KEY" "$SECRET_KEY" "$EXPORT_DIR" "$EXPORT_FORMAT" "$PORT" "$BAMBU_CMD_JSON" <<'PY'
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
log "Checking Onshape credentials (uv will fetch a Python + deps for this on first run)..."
"$UV_BIN" run --script "$APP_DIR/server/smoke_test.py" || die "Smoke test failed. Re-run this installer to fix your API key."

# ---------- 8. systemd --user service ----------
mkdir -p "$SYSTEMD_USER_DIR"
cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Onshape -> Bambu Studio bridge
After=network.target graphical-session.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR/server
ExecStart=$UV_BIN run --script $APP_DIR/server/main.py
Restart=on-failure
RestartSec=2
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable onshape-bambu-bridge.service
# `enable --now` is a no-op if the service is already running under an old
# unit file, so always restart explicitly to pick up ExecStart changes.
systemctl --user restart onshape-bambu-bridge.service

sleep 1
if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    log "Bridge is running: http://127.0.0.1:$PORT/health"
else
    warn "Bridge did not respond on port $PORT. Check: journalctl --user -u onshape-bambu-bridge -e"
fi

# ---------- 9. Userscript ----------
echo
log "Almost done — one browser step left for the Tampermonkey userscript."
echo "If Tampermonkey is already installed, opening the raw userscript URL shows"
echo "Tampermonkey's own 'Install this script?' page - one click and you're done."
echo "(Browsers don't allow silently installing extensions or userscripts from a"
echo "terminal, so this is as automated as it gets: two clicks, no copy/paste.)"
echo

# Pick the right extension store for the user's actual default browser
# (xdg-open just hands off to whatever that is - Firefox-family browsers
# can't install from the Chrome Web Store, and vice versa).
DEFAULT_BROWSER="$(xdg-settings get default-web-browser 2>/dev/null || true)"
DEFAULT_BROWSER="${DEFAULT_BROWSER,,}"
case "$DEFAULT_BROWSER" in
    *firefox*|*zen*|*librewolf*|*waterfox*|*floorp*|*seamonkey*|*icecat*)
        TAMPERMONKEY_URL="$TAMPERMONKEY_FIREFOX_URL"
        ;;
    *)
        TAMPERMONKEY_URL="$TAMPERMONKEY_CHROME_URL"
        ;;
esac

if command -v xdg-open >/dev/null 2>&1; then
    read -r -p "Open the Tampermonkey install page and the userscript install page now? [Y/n] " OPEN_BROWSER </dev/tty
    if [[ ! "$OPEN_BROWSER" =~ ^[Nn]$ ]]; then
        xdg-open "$TAMPERMONKEY_URL" >/dev/null 2>&1 &
        disown || true
        sleep 1
        xdg-open "$USERSCRIPT_RAW_URL" >/dev/null 2>&1 &
        disown || true
        log "Opened. Tab 1: install Tampermonkey if you haven't already. Tab 2: click Install."
    fi
else
    echo "Install Tampermonkey: $TAMPERMONKEY_URL"
    echo "(Chrome-family: $TAMPERMONKEY_CHROME_URL — Firefox-family: $TAMPERMONKEY_FIREFOX_URL)"
    echo "Then open this URL and click Install: $USERSCRIPT_RAW_URL"
fi

echo
echo "Manage the service with:"
echo "  systemctl --user status onshape-bambu-bridge"
echo "  journalctl --user -u onshape-bambu-bridge -f"
