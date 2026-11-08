#!/usr/bin/env python3
"""Exercise App ownership on fixtures without installing or changing system files."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class AppOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / 'Applications/Remote Buddy.app'
        self.app.mkdir(parents=True)
        (self.app / 'Contents').mkdir()
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.zfdang.remote-buddy',
            'CFBundleExecutable': 'RemoteBuddy',
        }))
        self.version = self.app / 'Contents/Frameworks/Sparkle.framework/Versions/B'
        self.version.mkdir(parents=True)
        (self.version.parent / 'Current').symlink_to('B', target_is_directory=True)
        self.helper = self.version / 'Autoupdate'
        self.helper.write_text('update helper fixture')
        self.staging = self.root / 'scripts'
        self.staging.mkdir()
        shutil.copy2(SCRIPTS / 'installation-common.sh', self.staging)
        self.script = self.staging / 'postinstall'
        self.source = (SCRIPTS / 'app-package/postinstall').read_text().replace(
            "app='/Applications/Remote Buddy.app'", f"app='{self.app}'")
        self.calls = self.root / 'calls'
        self.stub('/usr/bin/stat', 'echo 501')
        self.stub('/usr/bin/id', 'echo 20')
        self.stub('/usr/sbin/chown', 'exec /usr/bin/python3 -c '
            + "'import json,sys; open(sys.argv[1],\"a\").write(json.dumps(sys.argv[2:])+\"\\n\")' "
            + f'"{self.calls}" "$@"')
        self.driver_calls = self.root / 'driver-calls'
        self.driver_script = self.staging / 'driver-postinstall'
        self.driver_script.write_text(f'#!/bin/bash\nprintf "%s\\n" "$@" > "{self.driver_calls}"\n')

    def stub(self, command, body):
        target = self.staging / Path(command).name
        target.write_text('#!/bin/bash\n' + body + '\n')
        target.chmod(0o755)
        self.source = self.source.replace(command, str(target))

    def run_install(self, volume='/'):
        self.script.write_text(self.source)
        return subprocess.run(['bash', str(self.script), 'package.pkg', '/', volume],
                              capture_output=True, text=True)

    def test_only_app_is_assigned_to_console_user_and_driver_step_still_runs(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()], [
            ['-R', '-P', '-h', '501:20', str(self.app)], ['-h', '0:0', str(self.helper)]])
        self.assertEqual(self.driver_calls.read_text().splitlines(), ['package.pkg', '/', '/'])

    def test_no_desktop_user_or_offline_volume_keeps_system_ownership(self):
        for uid, volume in [('0', '/'), ('248', '/'), ('501', '/Volumes/Other')]:
            with self.subTest(uid=uid, volume=volume):
                (self.staging / 'stat').write_text(f'#!/bin/bash\necho {uid}\n')
                result = self.run_install(volume)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
                self.assertEqual(calls, [['-h', '0:0', str(self.helper)]] if volume == '/' else [])
                self.calls.unlink(missing_ok=True)
                self.assertTrue(self.driver_calls.exists())

    def test_foreign_app_and_top_level_symlink_are_refused(self):
        info = self.app / 'Contents/Info.plist'
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.example.other'}))
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertFalse(self.calls.exists())
        moved = self.app.with_name('Other.app')
        self.app.rename(moved)
        self.app.symlink_to(moved, target_is_directory=True)
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_failed_ownership_change_is_reported(self):
        (self.staging / 'chown').write_text('#!/bin/bash\nexit 1\n')
        self.assertNotEqual(self.run_install().returncode, 0)

    def test_helper_symlink_or_framework_escape_cannot_reassign_external_file(self):
        outside = self.root / 'outside'
        outside.mkdir()
        external = outside / 'Autoupdate'
        external.write_text('must not change')
        self.helper.unlink()
        self.helper.symlink_to(external)
        self.assertNotEqual(self.run_install().returncode, 0)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 1)  # No command assigning root ownership.
        self.calls.unlink()
        current = self.version.parent / 'Current'
        current.unlink()
        current.symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.run_install().returncode, 0)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertEqual(external.read_text(), 'must not change')

    def test_failed_root_helper_assignment_is_reported(self):
        (self.staging / 'chown').write_text('#!/bin/bash\n[[ "$1" != -h ]]\n')
        self.assertNotEqual(self.run_install().returncode, 0)

    def test_real_ownership_command_preserves_signature_modes_and_bundle_symlinks(self):
        # Build a minimal framework so this check needs no downloaded artifacts.
        framework = self.app / 'Contents/Frameworks/Sparkle.framework'
        resources = self.version / 'Resources'
        resources.mkdir()
        (resources / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.example.test-framework',
            'CFBundleExecutable': 'Sparkle', 'CFBundlePackageType': 'FMWK',
        }))
        for name in ['Resources', 'Sparkle', 'Autoupdate']:
            (framework / name).symlink_to('Versions/Current/' + name)
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-x', 'c', '-', '-o', str(self.version / 'Sparkle')],
                       input='void placeholder(void) {}', text=True, check=True)
        subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(self.helper)],
                       input='int main(void) { return 0; }', text=True, check=True)
        for code in [self.helper, self.version / 'Sparkle', framework]:
            subprocess.run(['codesign', '--force', '--sign', '-', str(code)], capture_output=True, check=True)
        executable = self.app / 'Contents/MacOS/RemoteBuddy'
        executable.parent.mkdir()
        subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(executable)],
                       input='int main(void) { return 0; }', text=True, check=True)
        link = self.app / 'Contents/executable-link'
        link.symlink_to('MacOS/RemoteBuddy')
        subprocess.run(['codesign', '--force', '--sign', '-', str(self.app)], capture_output=True, check=True)
        signature = (self.app / 'Contents/_CodeSignature/CodeResources').read_bytes()
        modes = executable.stat().st_mode
        # Use the actual recursive command, with this test user's existing ownership.
        # Record the invocation while executing chown on the disposable bundle.
        observer = self.staging / 'observe-chown'
        observer.write_text('#!/usr/bin/env python3\nimport json, subprocess, sys\n'
            f'open({str(self.calls)!r}, "a").write(json.dumps(sys.argv[1:])+"\\n")\n'
            '# Root assignment is observed, not executed by this unprivileged test.\n'
            'if sys.argv[1:3] != ["-h", "0:0"]:\n'
            '    subprocess.run(["/usr/sbin/chown", *sys.argv[1:]], check=True)\n')
        observer.chmod(0o755)
        self.source = self.source.replace(str(self.staging / 'chown'), str(observer))
        (self.staging / 'stat').write_text(f'#!/bin/bash\necho {os.getuid()}\n')
        (self.staging / 'id').write_text(f'#!/bin/bash\necho {os.getgid()}\n')
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertIn('-P', calls[0])
        self.assertEqual(calls[1], ['-h', '0:0', str(self.helper)])
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), 'MacOS/RemoteBuddy')
        self.assertEqual(executable.stat().st_mode, modes)
        self.assertEqual((self.app / 'Contents/_CodeSignature/CodeResources').read_bytes(), signature)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(self.app)], check=True)


if __name__ == '__main__':
    unittest.main()
