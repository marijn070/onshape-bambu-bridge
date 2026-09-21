# Onshape → Bambu Studio (Linux)

One-click "Send to Bambu" button inside Onshape, for Linux. Pick which parts
of the current Part Studio you want to print, and they're exported as
`.3mf`/`.stl` and loaded straight into Bambu Studio — no Downloads-folder
roundtrip.

This is a Linux port of
[adamgmakes/OnShape-BambuStudio-Bridge](https://github.com/adamgmakes/OnShape-BambuStudio-Bridge),
which does the same thing on Windows via a PowerShell installer and a
Startup-folder autostart. The Onshape API calls and the browser-side
userscript are unchanged; only the parts that were Windows-specific are
swapped out:

| | Windows (upstream) | Linux (this repo) |
|---|---|---|
| Install | `install.ps1` | `install.sh` |
| Python deps | `venv` + `pip install -r requirements.txt` | [`uv run --script`](https://docs.astral.sh/uv/guides/scripts/) — deps are declared inline in `main.py`, no venv to manage |
| Autostart | Startup folder `.vbs` | `systemd --user` service |
| Config location | `config.json` next to the code | `~/.config/onshape-bambu-bridge/config.json` |
| Launching Bambu Studio | path to `bambu-studio.exe` | `bambu_studio_cmd` — works with Flatpak, an AppImage, or a native binary |

## How it works

Onshape is a cloud CAD tool; Bambu Studio is a desktop app. A browser button
can't directly hand a file to a desktop program, so there are two pieces:

1. **A small Python (FastAPI) service** running as a `systemd --user`
   service on `127.0.0.1:7777`. It talks to the Onshape REST API to list and
   export parts, then launches Bambu Studio with the resulting files.
2. **A Tampermonkey userscript** that adds a "Send to Bambu" button to every
   Onshape document page. Clicking it calls the local service.

The service is bound to `127.0.0.1` only and CORS-locked to
`https://cad.onshape.com`, so nothing on the network can reach it.

When it launches Bambu Studio, it does so via a transient `systemd-run
--user --scope`, outside the bridge service's own cgroup. Without this, a
`systemctl --user restart` of the bridge would also kill your open Bambu
Studio window (systemd's default `KillMode=control-group` kills the whole
process tree of a service, and Bambu Studio would otherwise be a descendant
of it).

## Requirements

- Linux with a `systemd --user` session (true for most modern distros)
- [uv](https://docs.astral.sh/uv/) — the installer offers to install it for
  you if it's missing. uv provisions Python itself, so you don't need a
  system Python at all.
- Bambu Studio — Flatpak (`com.bambulab.BambuStudio`), AppImage, or a native
  binary all work
- [Tampermonkey](https://www.tampermonkey.net/) (or a compatible userscript
  manager) in your browser
- An Onshape account, plus a free API key pair (instructions below)

## Quick start

### 1. Get an Onshape API key

1. Sign in at [cad.onshape.com/user/developer](https://cad.onshape.com/user/developer).
2. Go to **API keys** → **Create new API key**.
3. Grant it at least **OAuth2Read** scope (read documents). Read/write are
   both fine.
4. Copy the **Access key** and **Secret key** — you'll paste them into the
   installer. The secret is shown only once.

### 2. Install

No git clone needed — the installer pulls the two files it needs
(`server/main.py`, `server/smoke_test.py`) straight from this repo:

```bash
curl -fsSL https://raw.githubusercontent.com/marijn070/onshape-bambu-bridge/main/install.sh | bash
```

It's an interactive script (asks for your API key, etc.), so read it first
if you'd rather not pipe straight into `bash`:

```bash
curl -fsSL https://raw.githubusercontent.com/marijn070/onshape-bambu-bridge/main/install.sh -o install.sh
less install.sh   # or your editor of choice
bash install.sh
```

Cloning the repo works too, and is the better option if you want to read or
modify the code long-term — `install.sh` detects it's running from a
checkout and uses those local files instead of downloading them:

```bash
git clone https://github.com/marijn070/onshape-bambu-bridge.git
cd onshape-bambu-bridge
./install.sh
```

Either way, the installer will:

- Check for `uv` and offer to install it if it's missing
- Prompt for your Onshape access + secret key (secret input is hidden)
- Auto-detect Bambu Studio (Flatpak, then PATH, then common AppImage
  locations; falls back to asking for a path)
- Write `~/.config/onshape-bambu-bridge/config.json` (`chmod 600`)
- Run a smoke test against the Onshape API (via `uv run --script`, which
  transparently fetches Python + dependencies on first run and caches them)
- Install and start a `systemd --user` service
- Offer to open the Tampermonkey + userscript install pages in your browser

Re-run `./install.sh` any time to update credentials or the detected Bambu
Studio path.

### 3. Install the userscript

The installer's last step opens two browser tabs for you: the Tampermonkey
extension page, and the userscript's raw GitHub URL. If Tampermonkey is
already installed, navigating to a `.user.js` URL makes Tampermonkey show
its own **Install this script?** page — click **Install** and you're done,
no copy-paste needed. (Browsers don't let a terminal script silently install
an extension or confirm that native dialog for you, so a human click on
each of those two pages is unavoidable — this just skips everything else.)

To do it manually instead:

1. Install [Tampermonkey](https://www.tampermonkey.net/).
2. Open [`userscript/onshape-bambu.user.js`](https://raw.githubusercontent.com/marijn070/onshape-bambu-bridge/main/userscript/onshape-bambu.user.js) —
   Tampermonkey should offer to install it directly. If not, copy the file's
   contents and use Tampermonkey icon → **Create a new script** → paste over
   the template → Ctrl+S.

Once installed this way, it **stays up to date on its own**: the script's
`@updateURL`/`@downloadURL` point at this raw GitHub file, so Tampermonkey
periodically checks it (and you can force a check any time from Tampermonkey
→ Dashboard → Check for userscript updates). No Greasy Fork or other
third-party registry needed for that part.

If you'd rather publish it there anyway — for discoverability, not because
it's required for updates — [Greasy Fork](https://greasyfork.org/) supports
"syncing" a listing from an external URL, so you could point it at this same
raw file and it'll pick up future commits automatically. That first
submission has to come from you, though: it needs your own Greasy Fork
account and going through their web form once. Ping me if you want a hand
drafting the listing text.

### 4. Use it

1. Open any Part Studio at `cad.onshape.com`.
2. A green **Send to Bambu** button appears bottom-right. Drag it anywhere —
   its position is remembered.
3. Click it → check the parts you want → **Export & Open** (launches Bambu
   Studio with the parts loaded) or **Export only** (overwrites files on
   disk without touching Bambu — then in an already-open Bambu window,
   **right-click the part → Reload from disk**).

If you're starting fresh, use **Export & Open** the first time so Bambu
launches with your parts loaded; use **Export only** for later iterations.

Optionally enable **Preferences → General → Single Instance** in Bambu
Studio so future launches route into your running window instead of
spawning a new one.

## Iteration workflow

1. Edit your model in Onshape.
2. Click **Send to Bambu** → **Export only**. This overwrites the file on
   disk without re-launching Bambu Studio.
3. In Bambu Studio: **right-click the part → Reload from disk**. Supports,
   plate position, and slicing settings are preserved — only geometry
   updates.

Exported files live at `<export_dir>/<DocName>__<ElementName>/` (default
`~/OnshapeExports`).

## Configuration

`~/.config/onshape-bambu-bridge/config.json` (see
[`config.example.json`](config.example.json) for the template):

| Field | What it does |
|---|---|
| `onshape_access_key` | Your Onshape API access key |
| `onshape_secret_key` | Your Onshape API secret key |
| `onshape_base_url` | Onshape host (default `https://cad.onshape.com`) |
| `bambu_studio_cmd` | Argv list used to launch Bambu Studio, e.g. `["flatpak", "run", "com.bambulab.BambuStudio"]` or `["/path/to/BambuStudio.AppImage"]` |
| `export_dir` | Where exports land (empty = `~/OnshapeExports`) |
| `export_format` | `"3MF"` or `"STL"` (3MF preserves more; STL exports faster) |
| `port` | Local port the bridge listens on (default `7777`) |

If you change `port`, also update the `BRIDGE` constant near the top of
`userscript/onshape-bambu.user.js` and re-save the userscript.

## Managing the bridge

**Is it running?**

```bash
curl http://127.0.0.1:7777/health
systemctl --user status onshape-bambu-bridge
```

**Logs:**

```bash
journalctl --user -u onshape-bambu-bridge -f
```

**Restart:**

```bash
systemctl --user restart onshape-bambu-bridge
```

**Disable autostart:**

```bash
systemctl --user disable --now onshape-bambu-bridge
```

**Uninstall everything:**

```bash
./uninstall.sh
# or, without a checkout:
curl -fsSL https://raw.githubusercontent.com/marijn070/onshape-bambu-bridge/main/uninstall.sh | bash
```

It stops and removes the systemd service and `~/.local/share/onshape-bambu-bridge`,
and asks before touching `~/.config/onshape-bambu-bridge` (your API key) —
say no to keep your config for a later reinstall.

## Project layout

```
onshape-bambu-bridge/
├─ install.sh                # Interactive installer
├─ uninstall.sh               # Stops the service and removes installed files
├─ config.example.json        # Template — install.sh writes the real one
├─ LICENSE                    # MIT
├─ README.md
├─ server/
│  ├─ main.py                 # FastAPI bridge service — deps declared inline (PEP 723), run via `uv run --script`
│  ├─ smoke_test.py           # Onshape auth check used by install.sh
│  └─ onshape-bambu-bridge.service.example  # Reference unit (install.sh generates the real one with resolved paths)
└─ userscript/
   └─ onshape-bambu.user.js   # Tampermonkey button + modal (unchanged from upstream)
```

## Security notes

- `config.json` lives under `~/.config/onshape-bambu-bridge/`, created
  `chmod 700`, with the file itself `chmod 600` — only your user can read
  the API key.
- The bridge listens on `127.0.0.1` only and accepts CORS only from
  `https://cad.onshape.com`. It is **not** exposed to your network.
- Any local program can call the bridge (it has no auth of its own). On a
  personal machine that's a non-issue; on a shared machine, consider adding
  a shared-secret header — PRs welcome.
- The Onshape secret key is stored in plaintext on disk. If you suspect it
  leaked, rotate it at [cad.onshape.com/user/developer](https://cad.onshape.com/user/developer).

## Troubleshooting

**"Could not reach bridge" in the userscript modal**
The service isn't running. Check `curl http://127.0.0.1:7777/health` and
`journalctl --user -u onshape-bambu-bridge -e`.

**"Unauthenticated API request" (401) from Onshape**
The API key didn't load correctly. Re-run `./install.sh` and re-enter your
keys.

**"Bambu Studio launcher not found ..."**
Edit `bambu_studio_cmd` in `config.json` to point at your real Bambu Studio
command, then `systemctl --user restart onshape-bambu-bridge`.

**Bambu Studio opens a new project instead of adding to my current plate**
Enable **Single Instance** in Bambu Studio preferences. Whether a new launch
then adds to the current plate vs. opens as a new project depends on Bambu
Studio's version — the **Reload from disk** workflow above sidesteps this
entirely.

**3MF export fails but STL works**
Set `"export_format": "STL"` in `config.json` as a workaround, restart the
service, and file an issue with the error from
`journalctl --user -u onshape-bambu-bridge`.

## Why not just use a slash/keyboard shortcut in Onshape?

Onshape doesn't expose desktop integration hooks — the closest built-in
option is **File → Download**, which still routes through your browser's
download folder. The userscript + local bridge is the most reliable way to
skip that roundtrip without writing a full Onshape App Store integration.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgments

Based on [adamgmakes/OnShape-BambuStudio-Bridge](https://github.com/adamgmakes/OnShape-BambuStudio-Bridge)
(Windows). Onshape's [public REST API](https://onshape-public.github.io/docs/)
makes the cloud side possible.
