#!/usr/bin/env python3
"""Verify complete-source archives cannot silently omit local changes."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('build-release-sources.sh')

class ReleaseSourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'third_party/blackhole').mkdir(parents=True)
        for name in ['build-release-sources.sh', 'architecture.sh', 'generate-appcast.py', 'verify-dependency-checkout.py']:
            shutil.copy2(SCRIPT.with_name(name), self.root / 'scripts' / name)
        shutil.copy2(SCRIPT.parent.parent / '.gitignore', self.root / '.gitignore')
        release_metadata = self.root / 'scripts/release-metadata.sh'
        release_metadata.write_text("#!/bin/bash\nprintf 'RELEASE_TAG=v26-10-11.001\\n'\n")
        release_metadata.chmod(0o755)
        blackhole = self.root / '.build/buddy-driver/BlackHole'
        sparkle = self.root / '.build/app-arm64/checkouts/Sparkle'
        for dependency in (blackhole, sparkle):
            dependency.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q'], cwd=dependency, check=True)
            (dependency / 'LICENSE').write_text('dependency license\n')
        (blackhole / 'device.c').write_text('original driver\n')
        for dependency in (blackhole, sparkle):
            subprocess.run(['git', 'add', '.'], cwd=dependency, check=True)
            subprocess.run(['git', '-c', 'user.name=Test Fixture', '-c', 'user.email=fixture@example.invalid',
                            'commit', '-qm', 'fixture'], cwd=dependency, check=True)
        blackhole_revision = subprocess.check_output(['git', '-C', str(blackhole), 'rev-parse', 'HEAD'], text=True).strip()
        sparkle_revision = subprocess.check_output(['git', '-C', str(sparkle), 'rev-parse', 'HEAD'], text=True).strip()
        # Driver sources are patched via the checked-in product patch during builds.
        (blackhole / 'device.c').write_text('patched driver\n')
        patch = subprocess.check_output(['git', '-C', str(blackhole), 'diff', '--binary', 'HEAD'])
        (self.root / 'third_party/blackhole/device-usb.patch').write_bytes(patch)
        (self.root / 'scripts/build-driver.sh').write_text(f'revision={blackhole_revision}\n')
        (self.root / 'Package.resolved').write_text(
            '{"pins":[{"identity":"sparkle","state":{"revision":"' + sparkle_revision + '"}}]}\n'
        )
        (self.root / 'source.swift').write_text('release source\n')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Test Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, check=True, capture_output=True)

    def package(self):
        return subprocess.run(['bash', 'scripts/build-release-sources.sh'], cwd=self.root,
                              env={**os.environ, 'RELEASE_TAG': 'v26-10-11.001', 'BUILD_ARCH': 'arm64'}, capture_output=True, text=True)

    def test_clean_tree_includes_matching_sources_and_licenses(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.root / 'dist/release/Remote_Buddy_v26-10-11.001_sources.tar.gz'
        with tarfile.open(archive) as files:
            base = 'Remote_Buddy_v26-10-11.001/'
            self.assertEqual(files.extractfile(base + 'source.swift').read(), b'release source\n')
            self.assertEqual(files.extractfile(base + 'vendor/BlackHole/device.c').read(), b'patched driver\n')
            for dep in ['BlackHole', 'Sparkle']:
                self.assertEqual(files.extractfile(base + f'vendor/{dep}/LICENSE').read(), b'dependency license\n')
                self.assertEqual(len(files.extractfile(base + f'vendor/{dep}.revision').read().strip()), 40)

    def test_imported_python_cache_does_not_block_source_archive(self):
        # Apple's local Python redirects caches to ~/Library/Caches; runners
        # use sibling __pycache__ directories. Exercise the runner layout.
        loader = "import sys, importlib.util; sys.pycache_prefix = None; sys.dont_write_bytecode = False; " + \
                 "spec = importlib.util.spec_from_file_location('appcast', 'scripts/generate-appcast.py'); " + \
                 "module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)"
        subprocess.run([sys.executable, '-c', loader], cwd=self.root, check=True)
        self.assertTrue(list((self.root / 'scripts/__pycache__').glob('*.pyc')))
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.root / 'dist/release/Remote_Buddy_v26-10-11.001_sources.tar.gz'
        with tarfile.open(archive) as files:
            self.assertFalse(any('__pycache__' in name or name.endswith('.pyc')
                                 for name in files.getnames()))

    def test_rejects_unstaged_source(self):
        (self.root / 'source.swift').write_text('uncommitted source\n')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dirty working tree', result.stderr)

    def test_rejects_staged_source(self):
        (self.root / 'source.swift').write_text('staged source\n')
        self.git('add', 'source.swift')
        self.assertNotEqual(self.package().returncode, 0)

    def test_rejects_untracked_source(self):
        (self.root / 'untracked.swift').write_text('untracked source\n')
        self.assertNotEqual(self.package().returncode, 0)

if __name__ == '__main__':
    unittest.main()
