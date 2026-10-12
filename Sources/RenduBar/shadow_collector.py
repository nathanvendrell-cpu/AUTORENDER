#!/usr/bin/env python3
"""One-shot, read-only Shadow export-folder probe. No daemon or render control."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile


CONNECTION_FILE = Path.home() / "Library" / "Application Support" / "RenduBar" / "connection.json"
ALLOWED = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".exr", ".mov", ".mp4", ".m4v", ".avi",
           ".wav", ".aif", ".aiff", ".flac", ".mp3", ".m4a", ".aac", ".ogg",
           ".pdf", ".glb", ".gltf", ".usdz"}
PREVIEWABLE = {".png", ".jpg", ".jpeg", ".tif", ".tiff"}
ACTIVE: subprocess.Popen[bytes] | None = None


def valid_path(value: str) -> bool:
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        return False
    if not re.fullmatch(r"[A-Za-z]:[/\\][^\r\n\x00]{1,390}", value):
        return False
    parts = value.replace("\\", "/").split("/")
    return ".." not in parts and all(c not in value for c in "'\"`$;")


def stop_active() -> None:
    global ACTIVE
    if ACTIVE is None or ACTIVE.poll() is not None:
        return
    try:
        os.killpg(ACTIVE.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        ACTIVE.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(ACTIVE.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        ACTIVE.wait(timeout=2)


def interrupt(signum: int, _frame: object) -> None:
    stop_active()
    raise KeyboardInterrupt(f"signal {signum}")


def run(argv: list[str], seconds: int) -> bytes:
    global ACTIVE
    ACTIVE = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              start_new_session=True)
    try:
        out, err = ACTIVE.communicate(timeout=seconds)
        if ACTIVE.returncode:
            raise RuntimeError(f"exit {ACTIVE.returncode}: {err.decode('utf-8', 'replace')[:300]}")
        return out
    except subprocess.TimeoutExpired as exc:
        stop_active()
        raise RuntimeError(f"timeout after {seconds}s") from exc
    finally:
        if ACTIVE is not None and ACTIVE.poll() is None:
            stop_active()
        if ACTIVE is not None:
            if ACTIVE.stdout is not None:
                ACTIVE.stdout.close()
            if ACTIVE.stderr is not None:
                ACTIVE.stderr.close()
        ACTIVE = None


def connection() -> tuple[str, str, Path]:
    try:
        data = json.loads(CONNECTION_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError("Shadow connection not configured") from exc
    host, user, identity_raw = data.get("host"), data.get("user"), data.get("identityFile")
    if not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]{0,252}", host):
        raise RuntimeError("invalid Shadow host")
    if not isinstance(user, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,31}", user):
        raise RuntimeError("invalid Shadow user")
    if not isinstance(identity_raw, str) or not Path(identity_raw).is_absolute():
        raise RuntimeError("invalid Shadow identity path")
    identity = Path(identity_raw)
    if not identity.is_file():
        raise RuntimeError("Shadow SSH identity unavailable")
    return host, user, identity


def ssh_base(identity: Path) -> list[str]:
    return ["-i", str(identity), "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=yes"]


def scan(roots: list[str], history: bool = False) -> dict[str, object]:
    if not roots:
        return {"ok": True, "files": []}
    if len(roots) > 12 or any(not valid_path(root) for root in roots):
        raise ValueError("invalid Shadow export folder")
    roots = list(dict.fromkeys(root.replace("\\", "/").rstrip("/").lower() for root in roots))
    quoted = ",".join("'" + root.replace("\\", "/") + "'" for root in roots)
    selection = "" if history else " | Select-Object -First 24"
    script = f"""
$ErrorActionPreference='Stop'
$roots=@({quoted})
$ext=@('.png','.jpg','.jpeg','.tif','.tiff','.exr','.mov','.mp4','.m4v','.avi',
  '.wav','.aif','.aiff','.flac','.mp3','.m4a','.aac','.ogg','.pdf','.glb','.gltf','.usdz')
$all=@()
$missing=@()
foreach($root in $roots) {{
  if(Test-Path -LiteralPath $root -PathType Container) {{
    $all += @(Get-ChildItem -LiteralPath $root -File -ErrorAction Stop |
      Where-Object {{ $ext -contains $_.Extension.ToLowerInvariant() -and $_.Length -gt 0 -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }} |
      Sort-Object LastWriteTimeUtc -Descending{selection} |
      ForEach-Object {{ [pscustomobject]@{{ root=$root; name=$_.Name; path=$_.FullName;
        bytes=$_.Length; modified=$_.LastWriteTimeUtc.ToString('o') }} }})
  }} else {{
    $missing += $root
  }}
}}
[pscustomobject]@{{ files=@($all); missing=@($missing) }} | ConvertTo-Json -Depth 4 -Compress
"""
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    host, user, identity = connection()
    data = run(["ssh", *ssh_base(identity), f"{user}@{host}",
                f"powershell -NoProfile -EncodedCommand {encoded}"], 18)
    text = data.decode("utf-8-sig", "replace").strip()
    parsed = json.loads(text[text.index("{"):])
    files = parsed.get("files") or []
    missing = parsed.get("missing") or []
    if isinstance(files, dict):
        files = [files]
    if isinstance(missing, str):
        missing = [missing]
    if not isinstance(files, list) or not isinstance(missing, list):
        raise RuntimeError("invalid Shadow scan response")
    return {"ok": True, "files": files, "missing": missing}


def preview(path: str, roots: list[str], output: Path) -> dict[str, object]:
    if not valid_path(path) or Path(path).suffix.lower() not in PREVIEWABLE:
        raise ValueError("invalid preview path")
    normalized = path.replace("\\", "/").lower()
    if not any(valid_path(root) and normalized.startswith(root.replace("\\", "/").rstrip("/").lower() + "/")
               for root in roots):
        raise ValueError("preview outside configured export folders")
    remote = "/" + path.replace("\\", "/")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rendubar-preview-") as temporary:
        original = Path(temporary) / ("source" + Path(path).suffix.lower())
        converted = Path(temporary) / "preview.jpg"
        host, user, identity = connection()
        run(["scp", "-q", *ssh_base(identity), f"{user}@{host}:{remote}", str(original)], 20)
        if not original.is_file() or original.stat().st_size == 0:
            raise RuntimeError("remote image empty")
        run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82",
             "-Z", "640", str(original), "--out", str(converted)], 12)
        if not converted.is_file() or converted.stat().st_size == 0:
            raise RuntimeError("preview conversion failed")
        os.replace(converted, output)
    return {"ok": True, "path": str(output), "bytes": output.stat().st_size}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["scan", "preview", "history"])
    parser.add_argument("--roots-json", required=True)
    parser.add_argument("--path")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    roots = json.loads(args.roots_json)
    if not isinstance(roots, list) or not all(isinstance(value, str) for value in roots):
        parser.error("roots must be string array")
    try:
        if args.mode in ("scan", "history"):
            result = scan(roots, history=args.mode == "history")
        else:
            if not args.path or args.output is None:
                parser.error("preview requires path and output")
            result = preview(args.path, roots, args.output)
    except BaseException as exc:
        result = {"ok": False, "error": str(exc)[:300]}
    finally:
        stop_active()
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    raise SystemExit(main())
