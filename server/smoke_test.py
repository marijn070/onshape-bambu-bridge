#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "httpx==0.27.2",
# ]
# ///
"""Quick Onshape API auth check used by install.sh."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import httpx

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "onshape-bambu-bridge"
CONFIG_PATH = CONFIG_DIR / "config.json"


def main() -> int:
    if not CONFIG_PATH.exists():
        print(f"FAIL: missing {CONFIG_PATH}")
        return 1
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig"))
    r = httpx.get(
        cfg["onshape_base_url"] + "/api/users/sessioninfo",
        auth=(cfg["onshape_access_key"], cfg["onshape_secret_key"]),
        headers={"Accept": "application/json"},
        timeout=15,
    )
    if r.status_code != 200:
        print(f"FAIL: HTTP {r.status_code} - {r.text[:200]}")
        return 1
    j = r.json()
    print(f"OK: {j.get('name')} <{j.get('email') or ''}>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
