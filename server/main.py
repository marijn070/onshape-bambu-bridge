#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "fastapi==0.115.0",
#     "uvicorn[standard]==0.30.6",
#     "httpx==0.27.2",
# ]
# ///
"""
Onshape -> Bambu Studio bridge (Linux).

Local HTTP service. The Tampermonkey userscript running on cad.onshape.com
calls this on localhost to list parts, export selected ones as STL/3MF, and
launch Bambu Studio with the resulting files.

Linux port of https://github.com/adamgmakes/OnShape-BambuStudio-Bridge -
same Onshape REST calls and the same userscript, but config lives under
XDG_CONFIG_HOME, the process runs via `uv run --script` (dependencies
above, no venv to manage) as a systemd --user service, and Bambu Studio is
launched via whatever command config.json points at (Flatpak, AppImage, or
a native binary all work).
"""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.exception_handlers import http_exception_handler
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

# Reuse uvicorn's own logger so entries land in `journalctl --user -u
# onshape-bambu-bridge` with the same formatting as its request logs.
logger = logging.getLogger("uvicorn.error")

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "onshape-bambu-bridge"
CONFIG_PATH = CONFIG_DIR / "config.json"


def load_config() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        sys.exit(f"Missing config file: {CONFIG_PATH}. Run install.sh first.")
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig"))
    if not cfg.get("export_dir"):
        cfg["export_dir"] = str(Path.home() / "OnshapeExports")
    cfg.setdefault("export_format", "3MF")  # "3MF" or "STL"
    cfg.setdefault("bambu_studio_cmd", ["flatpak", "run", "com.bambulab.BambuStudio"])
    Path(cfg["export_dir"]).mkdir(parents=True, exist_ok=True)
    return cfg


CFG = load_config()

app = FastAPI(title="Onshape-Bambu Bridge")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://cad.onshape.com"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


@app.exception_handler(HTTPException)
async def logged_http_exception(request: Request, exc: HTTPException):
    # Every raise HTTPException(...) below sends its detail message to the
    # browser, but nothing server-side otherwise - a 5xx here previously
    # left no trace in `journalctl`, only in whatever the Tampermonkey
    # modal briefly showed before you dismissed it.
    if exc.status_code >= 500:
        logger.error("%s %s -> %s: %s", request.method, request.url.path, exc.status_code, exc.detail)
    return await http_exception_handler(request, exc)


def onshape_client() -> httpx.Client:
    return httpx.Client(
        base_url=CFG["onshape_base_url"],
        auth=(CFG["onshape_access_key"], CFG["onshape_secret_key"]),
        headers={"Accept": "application/json;charset=UTF-8;qs=0.09"},
        timeout=60.0,
        follow_redirects=True,
    )


def onshape_get_follow(url: str, params: dict | None = None, headers: dict | None = None) -> httpx.Response:
    """GET that manually follows redirects, re-attaching Basic auth on any
    onshape.com host (httpx strips auth on cross-host redirects by design)."""
    auth = (CFG["onshape_access_key"], CFG["onshape_secret_key"])
    base = CFG["onshape_base_url"]
    next_url = url if url.startswith("http") else base + url
    next_params: dict | None = params
    for _ in range(5):
        with httpx.Client(timeout=120.0, follow_redirects=False) as c:
            host = httpx.URL(next_url).host
            send_auth = auth if host.endswith("onshape.com") else None
            r = c.get(next_url, params=next_params, headers=headers, auth=send_auth)
        if r.status_code in (301, 302, 303, 307, 308):
            loc = r.headers.get("Location")
            if not loc:
                return r
            next_url = loc
            next_params = None  # already baked into Location
            continue
        return r
    raise HTTPException(502, "Too many redirects from Onshape")


_SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def safe_filename(name: str) -> str:
    name = _SAFE_NAME.sub("_", name).strip("._") or "part"
    return name[:120]


class ExportRequest(BaseModel):
    documentId: str
    workspaceId: str
    elementId: str
    partIds: list[str]
    documentName: str | None = None
    elementName: str | None = None
    partNames: dict[str, str] | None = None
    openInBambu: bool = True


@app.get("/health")
def health() -> dict[str, Any]:
    return {"ok": True, "export_dir": CFG["export_dir"], "bambu_studio_cmd": CFG["bambu_studio_cmd"]}


@app.get("/parts")
def list_parts(documentId: str, workspaceId: str, elementId: str) -> dict[str, Any]:
    with onshape_client() as c:
        r = c.get(f"/api/parts/d/{documentId}/w/{workspaceId}/e/{elementId}")
        if r.status_code != 200:
            raise HTTPException(r.status_code, f"Onshape: {r.text[:300]}")
        data = r.json()
    parts = [
        {"partId": p["partId"], "name": p.get("name") or p["partId"]}
        for p in data
    ]
    return {"parts": parts}


_RETRYABLE_STATUS = 599  # internal marker, never sent to a client
_TRANSLATION_RETRIES = 2  # extra attempts after the first, on top of 1 initial try


def _attempt_export_3mf(document_id: str, workspace_id: str, element_id: str, part_id: str) -> bytes:
    """One attempt at exporting a part as 3MF via Onshape's async translation API.

    Flow: POST translation -> poll -> GET externaldata blob. Raises
    HTTPException(_RETRYABLE_STATUS, ...) when the translation itself
    reports FAILED - Onshape's translation queue is flaky and often
    succeeds on an identical retry a few seconds later.
    """
    auth = (CFG["onshape_access_key"], CFG["onshape_secret_key"])
    base = CFG["onshape_base_url"]
    create_url = f"{base}/api/partstudios/d/{document_id}/w/{workspace_id}/e/{element_id}/translations"
    payload = {
        "formatName": "3MF",
        "partIds": part_id,
        "storeInDocument": False,
        "units": "millimeter",
        "grouping": True,
        "mode": "binary",
        "distanceTolerance": 0.001,
        "angularTolerance": 0.1090830782496456,
        "maximumChordLength": 10,
    }
    with httpx.Client(timeout=60.0) as c:
        r = c.post(create_url, json=payload, auth=auth,
                   headers={"Accept": "application/json", "Content-Type": "application/json"})
    if r.status_code not in (200, 202):
        raise HTTPException(r.status_code, f"Onshape 3MF translation create failed: {r.text[:400]}")
    tid = r.json()["id"]

    # Poll
    poll_url = f"{base}/api/translations/{tid}"
    deadline = time.time() + 120
    while time.time() < deadline:
        with httpx.Client(timeout=30.0) as c:
            pr = c.get(poll_url, auth=auth, headers={"Accept": "application/json"})
        if pr.status_code != 200:
            raise HTTPException(pr.status_code, f"Translation poll failed: {pr.text[:400]}")
        body = pr.json()
        state = body.get("requestState")
        if state == "DONE":
            ext_ids = body.get("resultExternalDataIds") or []
            if not ext_ids:
                raise HTTPException(500, f"Translation finished but no result IDs: {body}")
            data_url = f"/api/documents/d/{document_id}/externaldata/{ext_ids[0]}"
            dr = onshape_get_follow(data_url, headers={"Accept": "application/octet-stream"})
            if dr.status_code != 200:
                raise HTTPException(dr.status_code, f"3MF download failed: {dr.text[:400]}")
            return dr.content
        if state == "FAILED":
            raise HTTPException(_RETRYABLE_STATUS, f"Translation failed: {body.get('failureReason')}")
        time.sleep(0.6)
    raise HTTPException(504, "Timed out waiting for Onshape 3MF translation")


def export_3mf(document_id: str, workspace_id: str, element_id: str, part_id: str) -> bytes:
    last_error: HTTPException | None = None
    for attempt in range(1 + _TRANSLATION_RETRIES):
        try:
            return _attempt_export_3mf(document_id, workspace_id, element_id, part_id)
        except HTTPException as e:
            if e.status_code != _RETRYABLE_STATUS:
                raise
            last_error = e
            if attempt < _TRANSLATION_RETRIES:
                time.sleep(1.5)
    assert last_error is not None
    raise HTTPException(500, last_error.detail)


def export_stl(document_id: str, workspace_id: str, element_id: str, part_id: str) -> bytes:
    """Synchronous STL export of a single part from a part studio.

    Onshape returns a 307 redirect to a presigned S3 URL. httpx strips the
    Authorization header on cross-host redirects (correct, since the S3 URL
    is presigned and Onshape's Basic auth would confuse S3).
    """
    url = f"/api/partstudios/d/{document_id}/w/{workspace_id}/e/{element_id}/stl"
    params = {"mode": "binary", "units": "millimeter", "partIds": part_id}
    r = onshape_get_follow(
        url, params=params,
        headers={"Accept": "application/vnd.onshape.v1+octet-stream"},
    )
    if r.status_code != 200:
        raise HTTPException(
            r.status_code,
            f"Onshape STL export failed ({r.status_code}): {r.text[:400]}",
        )
    return r.content


def launch_bambu(files: list[str]) -> None:
    cmd = [*CFG["bambu_studio_cmd"], *files]
    exe = cmd[0]

    # Only sanity-check absolute paths (AppImages, native binaries). A bare
    # command like "flatpak" is resolved against PATH by Popen itself.
    if Path(exe).is_absolute() and not Path(exe).exists():
        raise HTTPException(
            500,
            f"Bambu Studio launcher not found at {exe}. Update bambu_studio_cmd in {CONFIG_PATH}.",
        )

    # Run the launch through a transient systemd scope, outside the bridge
    # service's own cgroup. Without this, `systemctl --user restart` on the
    # bridge (KillMode=control-group, the default) would also kill Bambu
    # Studio, since it would otherwise be a descendant of the bridge process.
    if shutil.which("systemd-run"):
        cmd = ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--", *cmd]

    try:
        subprocess.Popen(cmd, close_fds=True, start_new_session=True)
    except FileNotFoundError as e:
        raise HTTPException(
            500,
            f"Could not launch Bambu Studio ({exe}): {e}. Update bambu_studio_cmd in {CONFIG_PATH}.",
        )


@app.post("/export")
def export(req: ExportRequest) -> dict[str, Any]:
    if not req.partIds:
        raise HTTPException(400, "No partIds provided")

    export_dir = Path(CFG["export_dir"])
    doc_label = safe_filename(req.documentName or req.documentId[:8])
    elem_label = safe_filename(req.elementName or req.elementId[:8])
    subdir = export_dir / f"{doc_label}__{elem_label}"
    subdir.mkdir(parents=True, exist_ok=True)

    fmt = (CFG.get("export_format") or "3MF").upper()
    exporter = export_3mf if fmt == "3MF" else export_stl
    ext = fmt.lower()

    written: list[str] = []
    for pid in req.partIds:
        pretty = (req.partNames or {}).get(pid) or pid
        fname = f"{safe_filename(pretty)}.{ext}"
        path = subdir / fname
        path.write_bytes(exporter(req.documentId, req.workspaceId, req.elementId, pid))
        written.append(str(path))

    launched = False
    if req.openInBambu and written:
        launch_bambu(written)
        launched = True

    return {"files": written, "launched": launched}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=CFG.get("port", 7777), log_level="info")
