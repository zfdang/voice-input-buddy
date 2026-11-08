#!/usr/bin/env python3
"""Exercise app assembly twice with a fixture compiler and signing failures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent.parent

class AppBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        shutil.copy2(SOURCE / 'scripts/build-app.sh', self.root / 'scripts/build-app.sh')
        for name in ['architecture.sh','thin-framework.py','verify-dependency-checkout.py','sign-bundle.sh']:
            shutil.copy2(SOURCE / 'scripts' / name, self.root / 'scripts' / name)
        shutil.copy2(SOURCE / 'scripts/generate-common-phrases.py', self.root / 'scripts/generate-common-phrases.py')
        shutil.copy2(SOURCE / 'scripts/verify-onboarding-resources.py', self.root / 'scripts/verify-onboarding-resources.py')
        shutil.copytree(SOURCE / 'Resources', self.root / 'Resources')
        (self.root / 'Sources').mkdir()
        shutil.copytree(SOURCE / 'Sources/VoiceInputBuddy',
                        self.root / 'Sources/VoiceInputBuddy')
        for name in ['LICENSE', 'THIRD_PARTY_NOTICES.md']:
            shutil.copy2(SOURCE / name, self.root / name)
        self.toolbin = self.root / 'tools'
        self.toolbin.mkdir()
        self.compilerbin = self.root / 'compiler'
        (self.compilerbin / 'Sparkle.framework').mkdir(parents=True)
        (self.compilerbin / 'Sparkle.framework/current').write_text('current framework')
        (self.compilerbin / 'VoiceInputBuddy').write_text('current executable')
        self.script(self.root / 'scripts/release-metadata.sh', "printf 'RELEASE_TAG=v26-10-11.001\\nRELEASE_BUNDLE_VERSION=26.10.11\\nRELEASE_COMMIT_COUNT=1\\nRELEASE_PACKAGE_VERSION=26.10.11.1\\n'\n")
        self.script(self.toolbin / 'swift', 'if [[ "$*" == *--show-bin-path* ]]; then printf "%s\\n" "$BUDDY_BUILD_FIXTURE_BIN"; fi\n')
        self.script(self.toolbin / 'lipo', 'cp "$2" "${@: -1}"\n')
        self.script(self.toolbin / 'otool', "printf 'cmd LC_RPATH\\npath @executable_path/../Frameworks\\n'\n")
        self.script(self.toolbin / 'codesign', '[[ "${BUDDY_BUILD_FIXTURE_FAIL_SIGN:-0}" != 1 ]]\n')
        self.app = self.root / 'dist/Voice Input Buddy.app'

    def script(self, path, body):
        path.write_text('#!/bin/bash\nset -euo pipefail\n' + body)
        path.chmod(0o755)

    def build(self, fail_sign=False):
        return subprocess.run(['bash', 'scripts/build-app.sh'], cwd=self.root,
            env={**os.environ, 'PATH': str(self.toolbin) + os.pathsep + os.environ['PATH'],
                 'BUDDY_BUILD_FIXTURE_BIN': str(self.compilerbin), 'BUILD_ARCH': 'arm64',
                 'BUDDY_BUILD_FIXTURE_FAIL_SIGN': '1' if fail_sign else '0'},
            capture_output=True, text=True)

    def test_rebuild_removes_retired_resources_and_frameworks(self):
        resource = self.root / 'Resources/retired.txt'
        resource.write_text('retired resource')
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.app / 'Contents/Resources/retired.txt').exists())
        notices = (self.app / 'Contents/Resources/THIRD_PARTY_NOTICES.md').read_text()
        self.assertIn('Copyright (c) 2006-2013 Andy Matuschak.', notices)
        self.assertIn('Permission is hereby granted, free of charge,', notices)
        self.assertIn('EXTERNAL LICENSES', notices)
        self.assertIn('Copyright 2003-2005 Colin Percival', notices)
        self.assertIn('Copyright (c) 2011 Mark Hamlin.', notices)
        self.assertIn('Copyright (C) 2019 Existential Audio Inc.', notices)
        self.assertIn('BlackHole-LICENSE', notices)
        self.assertFalse((self.app / 'Contents/Resources/AppIcon.iconset').exists())
        self.assertFalse((self.app / 'Contents/Resources/AppIcon.png').exists())
        self.assertTrue((self.app / 'Contents/Resources/AppIcon.icns').exists())
        self.assertFalse((self.app / 'Contents/Resources/RemoteIllustrations').exists())
        self.assertTrue((self.root / 'Resources/IconArtwork').is_dir())
        self.assertFalse((self.app / 'Contents/Resources/IconArtwork').exists())
        for name in ('ChromecastG9N9NIllustration', 'GoogleStreamerGY3LEIllustration', 'SiriRemoteA2854Illustration'):
            self.assertTrue((self.app / f'Contents/Resources/{name}.png').exists())
        phrases = json.loads((self.app / 'Contents/Resources/CommonPhrases.json').read_text())
        self.assertEqual(len(phrases['entries']), 12)
        self.assertEqual(phrases['bindings']['ok'], 'builtin-001')
        resource.unlink()
        (self.app / 'Contents/Frameworks/Retired.framework').mkdir()
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.app / 'Contents/Resources/retired.txt').exists())
        self.assertFalse((self.app / 'Contents/Frameworks/Retired.framework').exists())
        self.assertTrue((self.app / 'Contents/Frameworks/Sparkle.framework/current').exists())
        self.assertEqual(list((self.root / 'dist').glob('.app-build.*')), [])

    def test_failed_signing_preserves_previous_bundle(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.app / 'Contents/Resources/previous-build.txt'
        marker.write_text('keep previous build')
        result = self.build(fail_sign=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), 'keep previous build')
        self.assertEqual(list((self.root / 'dist').glob('.app-build.*')), [])

    def test_missing_planned_remote_image_preserves_previous_bundle(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('ChromecastG9N9NIllustration', 'GoogleStreamerGY3LEIllustration', 'SiriRemoteA2854Illustration'):
            self.assertTrue((self.app / f'Contents/Resources/{name}.png').exists())
        marker = self.app / 'Contents/Resources/previous-build.txt'
        marker.write_text('keep previous build')
        (self.root / 'Resources/GoogleStreamerGY3LEIllustration.png').unlink()
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('GoogleStreamerGY3LEIllustration.png', result.stderr)
        self.assertEqual(marker.read_text(), 'keep previous build')

    def test_missing_image_in_nested_guide_preserves_previous_bundle(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.app / 'Contents/Resources/previous-build.txt'
        marker.write_text('keep previous build')
        nested = self.root / 'Sources/VoiceInputBuddy/Onboarding/Guides'
        nested.mkdir()
        (nested / 'MissingImage.swift').write_text('let guide = .screenshot("missing-fixture")\n')
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing light screenshot: missing-fixture', result.stderr)
        self.assertEqual(marker.read_text(), 'keep previous build')

    def test_image_reference_outside_onboarding_is_still_validated(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.app / 'Contents/Resources/previous-build.txt'
        marker.write_text('keep previous build')
        nested = self.root / 'Sources/VoiceInputBuddy/Integrations/SharedGuides'
        nested.mkdir(parents=True)
        (nested / 'MissingImage.swift').write_text('let guide = .screenshot("missing-external-fixture")\n')
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing light screenshot: missing-external-fixture', result.stderr)
        self.assertEqual(marker.read_text(), 'keep previous build')

    def test_empty_setup_sources_cannot_silently_skip_resource_checks(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.app / 'Contents/Resources/previous-build.txt'
        marker.write_text('keep previous build')
        shutil.rmtree(self.root / 'Sources/VoiceInputBuddy/Onboarding')
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No onboarding sources found', result.stderr)
        self.assertEqual(marker.read_text(), 'keep previous build')

if __name__ == '__main__':
    unittest.main()
