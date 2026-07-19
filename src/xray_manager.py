from __future__ import annotations

import logging
import os
import platform
import shutil
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path
from typing import Callable, Optional

import requests

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BIN_DIR = PROJECT_ROOT / "bin"
XRAY_BIN_NAME = "xray.exe" if platform.system() == "Windows" else "xray"

GITHUB_API_LATEST = "https://api.github.com/repos/XTLS/Xray-core/releases/latest"
GITHUB_RELEASE_TAG_URL = (
    "https://github.com/XTLS/Xray-core/releases/download/{tag}/{asset}"
)
FALLBACK_VERSION = "v26.3.27"


def detect_arch() -> str:
    machine = platform.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "arm64-v8a"
    if machine in ("x86_64", "amd64", "i386", "i686"):
        if platform.system() == "Darwin":
            try:
                out = subprocess.check_output(
                    ["sysctl", "-n", "hw.optional.arm64"], text=True
                )
                if out.strip() == "1":
                    return "arm64-v8a"
            except Exception:
                pass
        return "64"
    return "64"


def asset_name_for_arch(arch: Optional[str] = None) -> str:
    arch = arch or detect_arch()
    system = platform.system()
    if system == "Darwin":
        return "Xray-macos-%s.zip" % arch
    if system == "Windows":
        return "Xray-windows-%s.zip" % ("arm64-v8a" if arch != "64" else "64")
    return "Xray-linux-%s.zip" % arch


def find_xray_binary(search_paths: Optional[list[Path]] = None) -> Optional[Path]:
    candidates: list[Path] = [BIN_DIR / XRAY_BIN_NAME]

    which = shutil.which("xray")
    if which:
        candidates.append(Path(which))

    if search_paths:
        candidates.extend(search_paths)

    for path in candidates:
        if path and path.is_file() and os.access(path, os.X_OK):
            return path.resolve()
    return None


def _download_file(
    url: str,
    dest: Path,
    progress_cb: Optional[Callable[[int, int], None]] = None,
    timeout: float = 120.0,
) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True, timeout=timeout) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        with open(dest, "wb") as f:
            for chunk in resp.iter_content(chunk_size=256 * 1024):
                if not chunk:
                    continue
                f.write(chunk)
                done += len(chunk)
                if progress_cb:
                    progress_cb(done, total)


def _resolve_download_url(arch: Optional[str] = None) -> tuple[str, str]:
    asset = asset_name_for_arch(arch)
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "velo",
    }
    try:
        resp = requests.get(GITHUB_API_LATEST, headers=headers, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        tag = data.get("tag_name") or FALLBACK_VERSION
        for a in data.get("assets") or []:
            name = a.get("name") or ""
            if name.lower() == asset.lower():
                url = a.get("browser_download_url")
                if url:
                    return url, tag
        return GITHUB_RELEASE_TAG_URL.format(tag=tag, asset=asset), tag
    except Exception as exc:
        logger.warning("release lookup failed (%s), using %s", exc, FALLBACK_VERSION)
        tag = FALLBACK_VERSION
        return GITHUB_RELEASE_TAG_URL.format(tag=tag, asset=asset), tag


def ensure_xray(
    force: bool = False,
    progress_cb: Optional[Callable[[str], None]] = None,
    download_progress_cb: Optional[Callable[[int, int], None]] = None,
) -> Path:
    def status(msg: str) -> None:
        logger.info(msg)
        if progress_cb:
            progress_cb(msg)

    if not force:
        existing = find_xray_binary()
        if existing:
            status("using xray-core at " + str(existing))
            return existing

    BIN_DIR.mkdir(parents=True, exist_ok=True)
    arch = detect_arch()
    asset = asset_name_for_arch(arch)
    status("downloading xray-core (%s)" % arch)

    url, tag = _resolve_download_url(arch)
    status("release %s" % tag)

    with tempfile.TemporaryDirectory(prefix="xray_dl_") as tmp:
        zip_path = Path(tmp) / asset
        try:
            _download_file(url, zip_path, progress_cb=download_progress_cb)
        except Exception as exc:
            raise RuntimeError("failed to download xray-core: %s" % exc) from exc

        status("extracting")
        try:
            with zipfile.ZipFile(zip_path, "r") as zf:
                members = zf.namelist()
                xray_member = None
                for m in members:
                    if Path(m).name in ("xray", "xray.exe"):
                        xray_member = m
                        break
                if not xray_member:
                    raise RuntimeError("xray binary missing from archive")
                target = BIN_DIR / XRAY_BIN_NAME
                with zf.open(xray_member) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)
        except zipfile.BadZipFile as exc:
            raise RuntimeError("invalid archive: %s" % exc) from exc

    target = BIN_DIR / XRAY_BIN_NAME
    mode = target.stat().st_mode
    target.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    if platform.system() == "Darwin":
        try:
            subprocess.run(
                ["xattr", "-d", "com.apple.quarantine", str(target)],
                capture_output=True,
                check=False,
            )
        except Exception:
            pass

    if not target.is_file() or not os.access(target, os.X_OK):
        raise RuntimeError("xray binary not executable: " + str(target))

    status("xray-core ready (%s)" % tag)
    return target.resolve()


def xray_version(xray_path: Path) -> str:
    try:
        out = subprocess.check_output(
            [str(xray_path), "version"],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        )
        return out.strip().splitlines()[0] if out.strip() else ""
    except Exception:
        return ""
