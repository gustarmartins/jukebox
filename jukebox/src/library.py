#!/usr/bin/env python3
"""Incremental local library indexing; TSV stays compatible with the TUI."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


AUDIO_EXTENSIONS = frozenset({".flac", ".mp3", ".ogg", ".opus", ".m4a", ".aac", ".wav", ".aiff", ".aif", ".alac", ".ape", ".wv"})


def clean_field(value: object) -> str:
    # Metadata is displayed in a terminal and serialized as one TSV row.
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(value or ""))


def supported_path(path: str) -> bool:
    # A line-based playlist cannot represent these paths faithfully.
    return Path(path).suffix.lower() in AUDIO_EXTENSIONS and not any(c in path for c in "\n\r\t\x1f")


def discover(directory: str) -> dict[str, list[int]]:
    files = {}
    for root, _dirs, names in os.walk(os.path.abspath(directory)):
        for name in names:
            path = os.path.join(root, name)
            if not supported_path(path):
                continue
            try:
                stat = os.stat(path)
                if os.path.isfile(path):
                    files[path] = [stat.st_mtime_ns, stat.st_size]
            except OSError:
                continue
    return files


def read_cache(path: Path) -> dict[str, list[str]]:
    try:
        rows = (line.rstrip("\n").split("\t") for line in path.read_text(encoding="utf-8").splitlines())
        return {row[0]: row[1:] for row in rows if len(row) == 8}
    except OSError:
        return {}


def atomic_write(path: Path, content: str) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def probe(path: str) -> tuple[str, list[str] | None]:
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", "--", path],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode:
            return path, None
        data = json.loads(result.stdout)
        fmt = data.get("format") or {}
        # Vorbis/Opus tags live on the audio stream rather than the container.
        tags = {}
        for stream in data.get("streams", []):
            if stream.get("codec_type") == "audio":
                tags.update(stream.get("tags") or {})
                break
        tags.update(fmt.get("tags") or {})
        tags = {str(key).lower(): value for key, value in tags.items()}

        def number(default: str, *keys: str) -> str:
            for key in keys:
                try:
                    return str(max(0, int(str(tags.get(key, "")).split("/")[0])))
                except ValueError:
                    continue
            return default

        fields = [tags.get("title") or Path(path).stem, tags.get("artist") or "Unknown",
                  tags.get("album") or "Unknown", tags.get("date") or tags.get("year") or "0",
                  fmt.get("duration") or "0", number("0", "track", "tracknumber"), number("1", "disc", "discnumber")]
        return path, [clean_field(field) for field in fields]
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return path, None


def refresh(directory: str, cache: Path, *, changed_path: str | None = None,
            osu_dir: str = "", osu_filters: str = "") -> None:
    cache.parent.mkdir(parents=True, exist_ok=True)
    # A watcher event must not append into an initial scan that later replaces it.
    with open(str(cache) + ".lock", "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = read_cache(cache)
        state_path = Path(str(cache) + ".files.json")
        try:
            signatures = json.loads(state_path.read_text(encoding="utf-8"))
            if not isinstance(signatures, dict):
                signatures = {}
        except (OSError, ValueError):
            signatures = {}
        if changed_path is None:
            disk = discover(directory)
            deleted = set(rows) - set(disk)
        else:
            path = os.path.abspath(changed_path)
            if not supported_path(path):
                return
            disk = {}
            if os.path.isfile(path):
                stat = os.stat(path)
                disk[path] = [stat.st_mtime_ns, stat.st_size]
            deleted = {path} - set(disk)
        for path in deleted:
            rows.pop(path, None)
            signatures.pop(path, None)
        pending = sorted(path for path, signature in disk.items()
                         if path not in rows or signatures.get(path) != signature)
        if pending:
            print(f"Library cache: probing {len(pending)} new/changed tracks...", file=sys.stderr, flush=True)
            with ThreadPoolExecutor(max_workers=min(4, len(pending))) as pool:
                for index, (path, fields) in enumerate(pool.map(probe, pending), 1):
                    if fields is not None:
                        rows[path] = fields
                        signatures[path] = disk[path]
                    else:
                        # Keep previous metadata on transient read failure; retry later.
                        signatures.pop(path, None)
                    if index % 25 == 0 or index == len(pending):
                        print(f"Library cache: {index}/{len(pending)} tracks", file=sys.stderr, flush=True)
        atomic_write(cache, "".join("\t".join([path, *rows[path]]) + "\n" for path in sorted(rows)))
        atomic_write(state_path, json.dumps(signatures))
        # Retain the owner's existing osu! scanner and settings integration.
        if osu_dir and changed_path is None:
            from osu_scanner import scan_osu_library
            scan_osu_library(osu_dir, osu_filters, str(cache))


def source_files(directory: str, cache: Path, order: str) -> list[str]:
    files = discover(directory)
    # Include additional sources supplied by the osu! scanner.
    for path in read_cache(cache):
        if path not in files and supported_path(path) and os.path.isfile(path):
            stat = os.stat(path)
            files[path] = [stat.st_mtime_ns, stat.st_size]
    if order.startswith("date_"):
        return sorted(files, key=lambda path: (files[path][0], path), reverse=order == "date_desc")
    return sorted(files, reverse=order == "name_desc")


def details(path: str, cache: Path) -> list[str]:
    """One bounded ffprobe replaces repeated probes for the Up Next panel."""
    data = {}
    try:
        result = subprocess.run(["ffprobe", "-v", "quiet", "-print_format", "json",
                                 "-show_format", "-show_streams", "--", path],
                                capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            data = json.loads(result.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    fmt = data.get("format") or {}
    audio = next((stream for stream in data.get("streams", []) if stream.get("codec_type") == "audio"), {})
    tags = {str(key).lower(): value for key, value in {**(audio.get("tags") or {}), **(fmt.get("tags") or {})}.items()}
    cached = read_cache(cache).get(path, [Path(path).stem, "", "", "", "0", "0", "1"])
    raw_title = tags.get("title")
    if (not raw_title or raw_title.lower() == "audio") and cached[0] and cached[0].lower() != "audio":
        title = cached[0]
    else:
        title = raw_title or cached[0] or Path(path).stem
    artist = tags.get("artist") or cached[1]
    album = tags.get("album") or cached[2]
    try:
        duration = float(fmt.get("duration") or cached[4])
        seconds = max(0, int(duration)) if math.isfinite(duration) else 0
    except (ValueError, TypeError):
        seconds = 0
    quality = [str(audio.get("codec_name") or Path(path).suffix.lstrip(".")).upper()]
    try:
        rate = int(audio.get("sample_rate", 0))
        if rate:
            quality.append(f"{rate / 1000:g} kHz")
        bits = int(audio.get("bits_per_raw_sample") or audio.get("bits_per_sample") or 0)
        if bits:
            quality.append(f"{bits}-bit")
        channels = int(audio.get("channels") or 0)
        if channels:
            quality.append({1: "Mono", 2: "Stereo"}.get(channels, f"{channels}ch"))
    except (ValueError, TypeError):
        pass
    try:
        size = os.stat(path).st_size
        size_label = (f"{size / 1073741824:.1f} GB" if size >= 1073741824 else
                      f"{size / 1048576:.1f} MB" if size >= 1048576 else f"{size / 1024:.0f} KB")
    except OSError:
        size_label = ""
    return [clean_field(value) for value in [title, artist, album, f"{seconds // 60:02d}:{seconds % 60:02d}",
            " · ".join(quality), size_label, tags.get("genre", ""), tags.get("date") or cached[3]]]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("scan", "list", "update", "details"))
    parser.add_argument("directory")
    parser.add_argument("cache", type=Path)
    parser.add_argument("--order", default="original")
    parser.add_argument("--path")
    parser.add_argument("--osu-dir", default="")
    parser.add_argument("--osu-filters", default="")
    args = parser.parse_args()
    if args.command == "details":
        print("\x1f".join(details(args.directory, args.cache)))
    elif args.command == "list":
        for path in source_files(args.directory, args.cache, args.order):
            print(path)
    else:
        if args.command == "update" and not args.path:
            parser.error("update requires --path")
        refresh(args.directory, args.cache, changed_path=args.path,
                osu_dir=args.osu_dir, osu_filters=args.osu_filters)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
