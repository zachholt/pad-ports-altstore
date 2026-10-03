#!/usr/bin/env python3
"""Bootstrap a pinned official PadMint release and pass through to its local UI/CLI."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / "catalog/padmint-tool.json").read_text())
MAX_FILES = 2000
MAX_UNPACKED = 64 * 1024 * 1024
MAX_ARCHIVE = 2 * 1024 * 1024


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def cache_root() -> Path:
    return Path.home() / "Library" / "Caches" / "pad-ports-altstore" / "padmint" / PIN["version"]


def ensure_no_symlink_path(path: Path, boundary: Optional[Path] = None) -> None:
    """Reject symlink components so cache operations cannot escape their owner directory."""
    absolute = path.expanduser().absolute()
    stop = boundary.expanduser().absolute() if boundary is not None else absolute
    if boundary is not None and stop not in (absolute, *absolute.parents):
        raise ValueError("Symlink-check boundary must be an ancestor of the path")
    for item in (absolute, *absolute.parents):
        try:
            mode = item.lstat().st_mode
        except FileNotFoundError:
            mode = None
        if mode is not None and stat.S_ISLNK(mode):
            raise ValueError(f"Refusing symlink in PadMint cache path: {item}")
        if item == stop:
            break


def read_archive(archive: Optional[Path]) -> bytes:
    if archive is not None:
        ensure_no_symlink_path(archive)
        data = archive.expanduser().read_bytes()
    else:
        cache = cache_root()
        ensure_no_symlink_path(cache, Path.home())
        archive_path = cache / "PadMint-macos.zip"
        if archive_path.exists():
            ensure_no_symlink_path(archive_path)
            data = archive_path.read_bytes()
        else:
            request = urllib.request.Request(PIN["macOSArchiveUrl"], headers={"User-Agent": "pad-ports-altstore"})
            with urllib.request.urlopen(request, timeout=60) as response:
                if not response.geturl().startswith("https://"):
                    raise ValueError("PadMint download did not remain on HTTPS")
                data = response.read(MAX_ARCHIVE + 1)
            if len(data) > MAX_ARCHIVE:
                raise ValueError("PadMint release archive exceeds the safe size limit")
            cache.mkdir(parents=True, exist_ok=True)
            ensure_no_symlink_path(cache, Path.home())
            fd, temporary = tempfile.mkstemp(prefix=".padmint-", dir=cache)
            try:
                with os.fdopen(fd, "wb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, archive_path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    if len(data) != PIN["macOSArchiveBytes"] or sha256(data) != PIN["macOSArchiveSha256"]:
        raise ValueError("PadMint archive size or SHA-256 does not match the pinned release")
    return data


def safe_members(zf: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    entries = zf.infolist()
    if len(entries) > MAX_FILES:
        raise ValueError("PadMint archive contains too many entries")
    seen: set[str] = set()
    total = 0
    root = PIN["archiveRoot"]
    for entry in entries:
        name = entry.filename
        if not name or "\\" in name or "\x00" in name:
            raise ValueError(f"Unsafe archive path: {name!r}")
        path = PurePosixPath(name)
        if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts) or ":" in path.parts[0]:
            raise ValueError(f"Unsafe archive path: {name!r}")
        if path.parts[0] != root:
            raise ValueError(f"Unexpected archive root: {name!r}")
        normalized = str(path).rstrip("/")
        if normalized in seen:
            raise ValueError(f"Duplicate archive path: {name!r}")
        seen.add(normalized)
        mode = (entry.external_attr >> 16) & 0xFFFF
        kind = stat.S_IFMT(mode)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise ValueError(f"Special file in PadMint archive: {name!r}")
        if entry.flag_bits & 1:
            raise ValueError("Encrypted PadMint archive entries are not supported")
        total += entry.file_size
        if total > MAX_UNPACKED:
            raise ValueError("PadMint archive expands beyond the safe size limit")
    return entries


def install_release(data: bytes) -> Path:
    base = cache_root()
    ensure_no_symlink_path(base, Path.home())
    base.mkdir(parents=True, exist_ok=True)
    ensure_no_symlink_path(base, Path.home())
    with zipfile.ZipFile(__import__("io").BytesIO(data)) as zf:
        entries = safe_members(zf)
        runtime = Path(tempfile.mkdtemp(prefix="run-", dir=base))
        try:
            for entry in entries:
                relative = PurePosixPath(entry.filename).relative_to(PIN["archiveRoot"])
                if not relative.parts:
                    continue
                destination = runtime.joinpath(*relative.parts)
                if entry.is_dir():
                    destination.mkdir(parents=True, exist_ok=True)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with zf.open(entry) as source, destination.open("xb") as target:
                        shutil.copyfileobj(source, target)
            expected = runtime / "PadMint.command"
            package = runtime / "padmint" / "__main__.py"
            if not expected.is_file() or not package.is_file():
                raise ValueError("Pinned PadMint archive is missing its official launcher or package")
            return runtime
        except Exception:
            shutil.rmtree(runtime)
            raise


def is_inside_git_repo(path: Path) -> bool:
    try:
        current = path.expanduser().resolve(strict=False)
    except (OSError, RuntimeError) as error:
        raise ValueError(f"Cannot safely resolve output path: {path}") from error
    for candidate in (current, *current.parents):
        if (candidate / ".git").exists():
            return True
    return False


def passthrough_args(arguments: list[str]) -> list[str]:
    if not arguments:
        return []
    command = arguments[0]
    if command not in {"list", "doctor", "make"}:
        raise ValueError("Supported commands are list, doctor, and make; omit the command to open PadMint's guided page")
    if command == "make":
        if len(arguments) < 3:
            raise ValueError("Usage: make GAME ios --disc /path/to/your-game-file [--out PRIVATE_FOLDER]")
        if "--out" not in arguments and not any(item.startswith("--out=") for item in arguments):
            arguments = [*arguments, "--out", str(Path.home() / "Downloads" / "PadPortsPersonalIPAs")]
        output = None
        index = 0
        while index < len(arguments):
            item = arguments[index]
            if item == "--disc" and index + 1 < len(arguments):
                arguments[index + 1] = str(Path(arguments[index + 1]).expanduser().absolute())
                index += 2
                continue
            if item.startswith("--disc="):
                arguments[index] = f"--disc={Path(item.split('=', 1)[1]).expanduser().absolute()}"
            elif item == "--out" and index + 1 < len(arguments):
                output = Path(arguments[index + 1]).expanduser().resolve(strict=False)
                arguments[index + 1] = str(output)
            elif item.startswith("--out="):
                output = Path(item.split("=", 1)[1]).expanduser().resolve(strict=False)
                arguments[index] = f"--out={output}"
            index += 1
        if output is not None and is_inside_git_repo(output):
            raise ValueError("Personal IPA output must be outside Git repositories; choose a private folder such as ~/Downloads/PadPortsPersonalIPAs")
    return arguments


def ensure_private_default_output(used_default: bool) -> None:
    if used_default:
        output = Path.home() / "Downloads" / "PadPortsPersonalIPAs"
        ensure_no_symlink_path(output, Path.home())
        output.mkdir(mode=0o700, parents=True, exist_ok=True)
        ensure_no_symlink_path(output, Path.home())
        output.chmod(0o700)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Launch the official pinned PadMint local builder")
    parser.add_argument("--prepare-only", action="store_true", help="Verify and prepare PadMint without opening it")
    parser.add_argument("--archive", type=Path, help="Use a local PadMint ZIP; the pinned size and hash are still required")
    parser.add_argument("padmint_args", nargs=argparse.REMAINDER, help="Optional PadMint command: list, doctor, or make")
    options = parser.parse_args(argv)
    app = None
    try:
        arguments = options.padmint_args
        if arguments and arguments[0] == "--":
            arguments = arguments[1:]
        arguments = passthrough_args(arguments)
        data = read_archive(options.archive)
        app = install_release(data)
        print(f"Verified PadMint {PIN['version']} in an isolated temporary runtime")
        if options.prepare_only:
            return 0
        if not arguments:
            arguments = ["ui", "--port", "0"]
        used_default_output = (arguments[0] == "make" and "--out" not in options.padmint_args
                               and not any(item.startswith("--out=") for item in options.padmint_args))
        ensure_private_default_output(used_default_output)
        command = [sys.executable, "-m", "padmint", *arguments]
        environment = dict(os.environ)
        environment["PYTHONUNBUFFERED"] = "1"
        return subprocess.run(command, cwd=app, env=environment, check=False).returncode
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"Make IPAs: {error}", file=sys.stderr)
        return 1
    finally:
        if app is not None and app.exists():
            ensure_no_symlink_path(app, cache_root())
            shutil.rmtree(app)


if __name__ == "__main__":
    raise SystemExit(main())
