#!/usr/bin/env python3
"""Verify deterministic Git mtime restoration and cache-marker change detection."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "restore_git_mtimes", Path(__file__).with_name("restore-git-mtimes.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class RestoreGitMtimesTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory()
        self.addCleanup(self.fixture.cleanup)
        self.repo = Path(self.fixture.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")

    def git(self, *args, env=None):
        merged = {**os.environ, **(env or {})}
        return subprocess.check_output(["git", "-C", str(self.repo), *args], env=merged, text=True).strip()

    def commit(self, rel_path: str, content: str, timestamp: int, msg: str) -> str:
        target = self.repo / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        self.git("add", rel_path)
        env = {"GIT_AUTHOR_DATE": f"{timestamp} +0000", "GIT_COMMITTER_DATE": f"{timestamp} +0000"}
        self.git("commit", "-m", msg, env=env)
        return self.git("rev-parse", "HEAD")

    def test_restores_per_file_commit_timestamps(self):
        self.commit("a.swift", "let a = 1\n", 1_700_000_100, "feat: add a")
        self.commit("b.swift", "let b = 1\n", 1_700_000_200, "feat: add b")
        os.utime(self.repo / "a.swift", (1_800_000_000, 1_800_000_000))
        os.utime(self.repo / "b.swift", (1_800_000_000, 1_800_000_000))

        updated, bumped = mod.restore_mtimes(self.repo)
        self.assertEqual(updated, 2)
        self.assertEqual(bumped, 0)
        self.assertEqual(int((self.repo / "a.swift").stat().st_mtime), 1_700_000_100)
        self.assertEqual(int((self.repo / "b.swift").stat().st_mtime), 1_700_000_200)

    def test_bumps_changed_files_when_commit_timestamp_is_not_newer_than_cached_sha(self):
        self.commit("a.swift", "let a = 1\n", 1_700_000_100, "feat: add a")
        cached_sha = self.commit("b.swift", "let b = 1\n", 1_700_000_200, "feat: add b")
        # Simulate a cherry-picked / backdated change to b.swift whose committer date equals cached_sha.
        self.commit("b.swift", "let b = 2\n", 1_700_000_200, "fix: update b same second")
        marker = self.repo / ".build/.cached-git-sha"
        marker.parent.mkdir(parents=True)
        marker.write_text(f"{cached_sha}\n", encoding="utf-8")

        updated, bumped = mod.restore_mtimes(self.repo, marker_file=marker, now=1_800_000_555)
        self.assertEqual(updated, 2)
        self.assertEqual(bumped, 1)
        self.assertEqual(int((self.repo / "a.swift").stat().st_mtime), 1_700_000_100)
        self.assertEqual(int((self.repo / "b.swift").stat().st_mtime), 1_800_000_555)

    def test_write_marker_records_head(self):
        sha = self.commit("a.swift", "let a = 1\n", 1_700_000_100, "feat: add a")
        marker = self.repo / ".build/.cached-git-sha"
        written = mod.write_marker(self.repo, marker)
        self.assertEqual(written, sha)
        self.assertEqual(marker.read_text(encoding="utf-8").strip(), sha)


if __name__ == "__main__":
    unittest.main()
