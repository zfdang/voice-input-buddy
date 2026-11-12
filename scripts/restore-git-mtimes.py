#!/usr/bin/env python3
"""Restore deterministic Git commit timestamps so SwiftPM caches survive fresh CI checkouts."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time


def git_tracked_files(repo: Path) -> set[str]:
    raw = subprocess.check_output(["git", "-C", str(repo), "ls-files", "-z"])
    return {p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p}


def git_commit_timestamps(repo: Path, tracked: set[str]) -> dict[str, int]:
    """Return the latest committer Unix timestamp for each tracked file using first-parent history."""
    remaining = set(tracked)
    timestamps: dict[str, int] = {}
    if not remaining:
        return timestamps
    proc = subprocess.Popen(
        [
            "git",
            "-C",
            str(repo),
            "log",
            "-m",
            "--first-parent",
            "--no-renames",
            "-z",
            "--pretty=format:__COMMIT__%ct%x00",
            "--name-only",
            "HEAD",
        ],
        stdout=subprocess.PIPE,
    )
    assert proc.stdout is not None
    current_ts: int | None = None
    buf = b""
    try:
        while remaining:
            chunk = proc.stdout.read(65536)
            if not chunk:
                break
            buf += chunk
            parts = buf.split(b"\0")
            buf = parts.pop()
            for token in parts:
                token = token.lstrip(b"\n")
                if not token:
                    continue
                text = token.decode("utf-8", "surrogateescape")
                if text.startswith("__COMMIT__"):
                    current_ts = int(text[10:])
                elif current_ts is not None and text in remaining:
                    timestamps[text] = current_ts
                    remaining.remove(text)
                    if not remaining:
                        break
        if buf and remaining and current_ts is not None:
            text = buf.lstrip(b"\n").decode("utf-8", "surrogateescape")
            if text in remaining:
                timestamps[text] = current_ts
    finally:
        proc.stdout.close()
        if proc.poll() is None:
            proc.terminate()
        proc.wait()
    return timestamps


def commit_timestamp(repo: Path, rev: str) -> int | None:
    try:
        subprocess.check_call(
            ["git", "-C", str(repo), "cat-file", "-e", f"{rev}^{{commit}}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        out = subprocess.check_output(
            ["git", "-C", str(repo), "show", "-s", "--format=%ct", rev],
            text=True,
        ).strip()
        return int(out)
    except (subprocess.CalledProcessError, ValueError):
        return None


def changed_since_marker(repo: Path, cached_sha: str) -> set[str]:
    raw = subprocess.check_output(
        ["git", "-C", str(repo), "diff", "--name-only", "-z", f"{cached_sha}..HEAD"]
    )
    return {p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p}


def restore_mtimes(repo: Path, marker_file: Path | None = None, now: int | None = None) -> tuple[int, int]:
    tracked = git_tracked_files(repo)
    timestamps = git_commit_timestamps(repo, tracked)
    bump_paths: set[str] = set()
    cached_ts: int | None = None
    if marker_file is not None and marker_file.is_file():
        cached_sha = marker_file.read_text(encoding="utf-8").strip()
        if cached_sha:
            cached_ts = commit_timestamp(repo, cached_sha)
            if cached_ts is not None:
                bump_paths = changed_since_marker(repo, cached_sha) & tracked
    fallback_now = int(time.time()) if now is None else now
    updated = 0
    bumped = 0
    for rel_path, ts in timestamps.items():
        target = repo / rel_path
        if not target.exists() or target.is_symlink():
            continue
        effective_ts = ts
        if rel_path in bump_paths and cached_ts is not None and ts <= cached_ts:
            effective_ts = max(fallback_now, cached_ts + 1)
            bumped += 1
        os.utime(target, (effective_ts, effective_ts))
        updated += 1
    return updated, bumped


def write_marker(repo: Path, marker_file: Path) -> str:
    sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    marker_file.parent.mkdir(parents=True, exist_ok=True)
    marker_file.write_text(f"{sha}\n", encoding="utf-8")
    return sha


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--marker-file", type=Path, default=None)
    parser.add_argument("--write-marker", action="store_true")
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    marker = args.marker_file.resolve() if args.marker_file is not None else None
    if args.write_marker:
        if marker is None:
            parser.error("--write-marker requires --marker-file")
        sha = write_marker(repo, marker)
        print(f"Wrote build cache marker {sha} -> {marker}")
        return 0
    updated, bumped = restore_mtimes(repo, marker_file=marker)
    print(f"Restored Git commit timestamps for {updated} tracked files ({bumped} bumped against cache marker).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
