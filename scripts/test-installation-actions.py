#!/usr/bin/env python3
"""Exercise removal and installation actions only against disposable fixtures."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
class InstallationActionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.library = SCRIPTS / 'installation-common.sh'

    def bundle(self, path, identity):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identity}))
        return path

    def remove(self, path, identity):
        return subprocess.run(['bash', '-c', 'source "$1"; buddy_remove_bundle "$2" "$3"',
                               'test', str(self.library), str(path), identity], capture_output=True)

    def test_product_bundle_is_removed_and_repeat_is_safe(self):
        bundle = self.bundle(self.root / 'app.app', 'com.zfdang.voice-input-buddy')
        self.assertEqual(self.remove(bundle, 'com.zfdang.voice-input-buddy').returncode, 0)
        self.assertFalse(bundle.exists())
        self.assertEqual(self.remove(bundle, 'com.zfdang.voice-input-buddy').returncode, 0)

    def test_foreign_bundle_and_symlink_are_refused(self):
        bundle = self.bundle(self.root / 'foreign.driver', 'com.example.other')
        self.assertNotEqual(self.remove(bundle, 'com.zfdang.voice-input-buddy.mic').returncode, 0)
        self.assertTrue(bundle.exists())
        owned = self.bundle(self.root / 'owned.driver', 'com.zfdang.voice-input-buddy.mic')
        link = self.root / 'link.driver'; link.symlink_to(owned, target_is_directory=True)
        self.assertNotEqual(self.remove(link, 'com.zfdang.voice-input-buddy.mic').returncode, 0)
        self.assertTrue(owned.exists())

    def test_installation_preserves_current_driver_and_other_bundles(self):
        hal = self.root / 'Library/Audio/Plug-Ins/HAL'
        other = self.bundle(hal / 'OtherMicrophone.driver', 'com.example.microphone')
        new = self.bundle(hal / 'VoiceInputBuddyMic.driver', 'com.zfdang.voice-input-buddy.mic')
        staging = self.root / 'package-scripts'; staging.mkdir()
        for source in [self.library, SCRIPTS / 'driver-package/preinstall']:
            shutil.copy2(source, staging / source.name)
        result = subprocess.run(['bash', str(staging / 'preinstall'), 'package.pkg', '/', str(self.root)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(other.exists()); self.assertTrue(new.exists())

    def test_preinstall_can_repair_missing_or_invalid_product_metadata(self):
        staging = self.root / 'package-scripts'; staging.mkdir()
        for source in [self.library, SCRIPTS / 'driver-package/preinstall']:
            shutil.copy2(source, staging / source.name)
        for invalid in [False, True]:
            volume = self.root / str(invalid)
            driver = volume / 'Library/Audio/Plug-Ins/HAL/VoiceInputBuddyMic.driver'
            (driver / 'Contents').mkdir(parents=True)
            if invalid:
                (driver / 'Contents/Info.plist').write_text('broken plist')
            result = subprocess.run(['bash', str(staging / 'preinstall'), 'package.pkg', '/', str(volume)],
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Permitting repair must not weaken removal validation.
            self.assertNotEqual(self.remove(driver, 'com.zfdang.voice-input-buddy.mic').returncode, 0)
            link = volume / 'Applications/Voice Input Buddy.app'
            link.parent.mkdir()
            link.symlink_to(driver, target_is_directory=True)
            result = subprocess.run(['bash', str(staging / 'preinstall'), 'package.pkg', '/', str(volume)],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_user_uninstaller_only_executes_an_intact_signed_app(self):
        staging = self.root / 'uninstall'; staging.mkdir()
        shutil.copy2(self.library, staging / self.library.name)
        app = self.bundle(self.root / 'Voice Input Buddy.app', 'com.zfdang.voice-input-buddy')
        info = app / 'Contents/Info.plist'
        metadata = plistlib.loads(info.read_bytes())
        metadata.update(CFBundleExecutable='VoiceInputBuddy', CFBundlePackageType='APPL',
                        BuddySupportsUninstallPreparation=True)
        info.write_bytes(plistlib.dumps(metadata))
        executable = app / 'Contents/MacOS/VoiceInputBuddy'
        executable.parent.mkdir()
        subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(executable)],
                       input='int main(void) { return 0; }', text=True, check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)],
                       capture_output=True, check=True)
        source = (SCRIPTS / 'uninstaller/uninstall-user.sh').read_text()
        source = source.replace("app='/Applications/Voice Input Buddy.app'", f"app='{app}'")
        for original, name, body in [('/usr/bin/id', 'id', 'echo 501'),
                                     ('/usr/bin/pkill', 'pkill', 'exit 1'),
                                     ('/usr/bin/pgrep', 'pgrep', 'exit 1')]:
            tool = staging / name
            tool.write_text('#!/bin/bash\n' + body + '\n')
            tool.chmod(0o755)
            source = source.replace(original, str(tool))
        script = staging / 'uninstall-user.sh'; script.write_text(source)
        result = subprocess.run(['bash', str(script), 'prepare'], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        # An intact app whose service unregister fails must not block removal.
        subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(executable)],
                       input='int main(void) { return 37; }', text=True, check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)],
                       capture_output=True, check=True)
        result = subprocess.run(['bash', str(script), 'prepare'], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'login-item removal failed', result.stderr)
        # Tampering must skip execution (which would fail with status 37).
        executable.write_text('#!/bin/bash\nexit 37\n')
        result = subprocess.run(['bash', str(script), 'prepare'], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'signature is invalid', result.stderr)

    def test_user_uninstaller_force_kills_app_when_graceful_quit_times_out(self):
        staging = self.root / 'uninstall-force'
        staging.mkdir()
        shutil.copy2(self.library, staging / self.library.name)
        source = (SCRIPTS / 'uninstaller/uninstall-user.sh').read_text()
        source = source.replace("app='/Applications/Voice Input Buddy.app'", f"app='{self.root / 'missing.app'}'")
        state_file = staging / 'pkill_calls'
        pkill_body = f'#!/bin/bash\necho "$@" >> "{state_file}"\nexit 0\n'
        pgrep_body = f'#!/bin/bash\nif grep -q -- "-9" "{state_file}" 2>/dev/null; then\n    exit 1\nfi\nexit 0\n'
        for original, name, body in [('/usr/bin/id', 'id', 'echo 501\n'),
                                     ('/usr/bin/pkill', 'pkill', pkill_body),
                                     ('/usr/bin/pgrep', 'pgrep', pgrep_body)]:
            tool = staging / name
            tool.write_text(body)
            tool.chmod(0o755)
            source = source.replace(original, str(tool))
        source = source.replace('/bin/sleep 0.1', '/bin/sleep 0.001')
        script = staging / 'uninstall-user.sh'
        script.write_text(source)
        result = subprocess.run(['bash', str(script), 'prepare'], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = state_file.read_text().splitlines()
        self.assertTrue(any('-9' in call for call in calls), f"Expected -9 in pkill calls: {calls}")

    def test_cleanup_rejects_missing_relative_root_and_symlink_homes(self):
        link = self.root / 'linked-home'
        link.symlink_to(self.root, target_is_directory=True)
        for home in ['', '/', '///', str(self.root / 'missing'), 'relative', str(link)]:
            with self.subTest(home=home):
                result = subprocess.run(['bash', '-c', 'source "$1"; buddy_cleanup_user_data "$2"',
                                         'test', str(self.library), home], capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_cleanup_only_removes_this_products_personal_data(self):
        for relative in ['Preferences/com.zfdang.voice-input-buddy.plist',
                         'Application Support/VoiceInputBuddy', 'Logs/VoiceInputBuddy',
                         'Caches/com.zfdang.voice-input-buddy',
                         'Saved Application State/com.zfdang.voice-input-buddy.savedState']:
            (self.root / 'Library' / relative).mkdir(parents=True)
        other = self.root / 'Library/Logs/other-app'; other.mkdir()
        result = subprocess.run(['bash', '-c', 'source "$1"; buddy_cleanup_user_data "$2"',
                                  'test', str(self.library), str(self.root)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(other.exists())
        self.assertFalse((self.root / 'Library/Logs/VoiceInputBuddy').exists())
        self.assertFalse((self.root / 'Library/Preferences/com.zfdang.voice-input-buddy.plist').exists())

    def test_preinstall_refuses_foreign_app_or_driver_before_overwriting(self):
        staging = self.root / 'package-scripts'; staging.mkdir()
        for source in [self.library, SCRIPTS / 'driver-package/preinstall']:
            shutil.copy2(source, staging / source.name)
        for foreign_app in [True, False]:
            with self.subTest(foreign_app=foreign_app):
                volume = self.root / str(foreign_app)
                app = self.bundle(volume / 'Applications/Voice Input Buddy.app',
                                  'com.example.foreign' if foreign_app else 'com.zfdang.voice-input-buddy')
                driver = self.bundle(volume / 'Library/Audio/Plug-Ins/HAL/VoiceInputBuddyMic.driver',
                                     'com.zfdang.voice-input-buddy.mic' if foreign_app else 'com.example.foreign')
                result = subprocess.run(['bash', str(staging / 'preinstall'), 'package.pkg', '/', str(volume)],
                                        capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(app.exists())
                self.assertTrue(driver.exists())

    def test_removed_driver_reports_restart_without_failing_when_daemon_already_exited(self):
        app = self.bundle(self.root / 'test.app', 'com.zfdang.voice-input-buddy')
        driver = self.bundle(self.root / 'test.driver', 'com.zfdang.voice-input-buddy.mic')
        staging = self.root / 'uninstall'; staging.mkdir()
        shutil.copy2(self.library, staging / self.library.name)
        source = (SCRIPTS / 'uninstaller/uninstall-system.sh').read_text()
        source = source.replace("app='/Applications/Voice Input Buddy.app'", f"app='{app}'")
        source = source.replace("driver='/Library/Audio/Plug-Ins/HAL/VoiceInputBuddyMic.driver'", f"driver='{driver}'")
        for original, name, body in [('/usr/bin/id', 'id', 'echo 0'),
                                     ('/usr/sbin/pkgutil', 'pkgutil', 'exit 0'),
                                     ('/usr/bin/pgrep', 'pgrep', 'exit 0'),
                                     ('/usr/bin/killall', 'killall', 'exit 1')]:
            tool = staging / name
            tool.write_text('#!/bin/bash\n' + body + '\n')
            tool.chmod(0o755)
            source = source.replace(original, str(tool))
        script = staging / 'uninstall-system.sh'
        script.write_text(source)
        result = subprocess.run(['bash', str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('restart your Mac', result.stderr)
        self.assertFalse(app.exists())
        self.assertFalse(driver.exists())

class DriverRestartTests(unittest.TestCase):
    """Run real signing checks on fixtures; never touch the system audio daemon."""

    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.fixtures.cleanup)
        root = Path(cls.fixtures.name)
        cls.original = root / 'original.driver'
        cls.changed = root / 'changed.driver'
        for bundle, value in [(cls.original, 1), (cls.changed, 2)]:
            executable = bundle / 'Contents/MacOS/Microphone'
            executable.parent.mkdir(parents=True)
            (bundle / 'Contents/Resources').mkdir()
            (bundle / 'Contents/Resources/config.txt').write_text('original resource')
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.zfdang.voice-input-buddy.mic',
                'CFBundleExecutable': 'Microphone',
                'CFBundlePackageType': 'BNDL',
                'CFBundleVersion': '3',
            }))
            subprocess.run(['xcrun', 'clang', '-x', 'c', '-bundle', '-', '-o', str(executable)],
                           input=f'int microphone(void) {{ return {value}; }}', text=True, check=True)
            cls.sign(bundle)

    @staticmethod
    def sign(bundle):
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(bundle)],
                       capture_output=True, check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.driver = self.root / 'Library/Audio/Plug-Ins/HAL/VoiceInputBuddyMic.driver'
        self.driver.parent.mkdir(parents=True)
        self.staging = self.root / 'scripts'
        self.staging.mkdir()
        self.calls = self.staging / 'audio-calls'
        for source in [SCRIPTS / 'installation-common.sh', SCRIPTS / 'driver-package/preinstall',
                       SCRIPTS / 'driver-package/postinstall']:
            shutil.copy2(source, self.staging / source.name)
        # Replace only daemon commands; fingerprint verification uses real codesign.
        postinstall = self.staging / 'postinstall'
        source = postinstall.read_text()
        for command in ['pgrep', 'killall']:
            stub = self.staging / command
            source = source.replace('/usr/bin/' + command, str(stub))
            self.stub(command, 0)
        postinstall.write_text(source)

    def stub(self, command, status):
        path = self.staging / command
        path.write_text(f'#!/bin/bash\necho {command} >> "{self.calls}"\nexit {status}\n')
        path.chmod(0o755)

    def install_driver(self, source):
        if self.driver.exists():
            shutil.rmtree(self.driver)
        shutil.copytree(source, self.driver)

    def run_script(self, name):
        result = subprocess.run(['bash', str(self.staging / name), 'package.pkg', '/', str(self.root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def assert_restarted(self, expected):
        self.run_script('postinstall')
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        self.assertEqual(calls, ['pgrep', 'killall'] if expected else [])
        self.assertFalse((self.staging / 'driver-before-install.cdhash').exists())

    def test_same_driver_skips_daemon_commands_after_payload_replacement(self):
        self.install_driver(self.original)
        self.run_script('preinstall')
        self.install_driver(self.original)
        self.assert_restarted(False)

    def test_resigning_identical_driver_skips_restart(self):
        self.install_driver(self.original)
        self.run_script('preinstall')
        self.sign(self.driver)
        self.assert_restarted(False)

    def test_first_install_restarts_and_overwrites_stale_snapshot(self):
        (self.staging / 'driver-before-install.cdhash').write_text('stale fingerprint')
        self.run_script('preinstall')
        self.assertEqual((self.staging / 'driver-before-install.cdhash').read_text(), '')
        self.install_driver(self.original)
        self.assert_restarted(True)

    def test_code_change_with_same_version_restarts(self):
        self.install_driver(self.original)
        self.run_script('preinstall')
        self.install_driver(self.changed)
        self.assert_restarted(True)

    def test_sealed_resource_change_restarts(self):
        self.install_driver(self.original)
        self.run_script('preinstall')
        (self.driver / 'Contents/Resources/config.txt').write_text('new resource')
        self.sign(self.driver)
        self.assert_restarted(True)

    def test_metadata_change_restarts(self):
        self.install_driver(self.original)
        self.run_script('preinstall')
        info = self.driver / 'Contents/Info.plist'
        metadata = plistlib.loads(info.read_bytes())
        metadata['CFBundleVersion'] = '4'
        info.write_bytes(plistlib.dumps(metadata))
        self.sign(self.driver)
        self.assert_restarted(True)

    def test_repairing_invalid_signature_restarts(self):
        self.install_driver(self.original)
        (self.driver / 'Contents/Resources/config.txt').write_text('damaged resource')
        self.run_script('preinstall')
        self.install_driver(self.original)
        self.assert_restarted(True)

    def test_invalid_installed_signature_does_not_skip_restart(self):
        self.install_driver(self.original)
        self.run_script('preinstall')
        (self.driver / 'Contents/Resources/config.txt').write_text('damaged resource')
        self.assert_restarted(True)

    def test_missing_snapshot_does_not_skip_restart(self):
        self.install_driver(self.original)
        self.assert_restarted(True)

    def test_absent_daemon_is_not_killed(self):
        self.run_script('preinstall')
        self.install_driver(self.original)
        self.stub('pgrep', 1)
        self.run_script('postinstall')
        self.assertEqual(self.calls.read_text().splitlines(), ['pgrep'])

    def test_failed_restart_keeps_install_success_and_reports_reboot(self):
        self.run_script('preinstall')
        self.install_driver(self.original)
        self.stub('killall', 1)
        result = self.run_script('postinstall')
        self.assertIn('Restart your Mac', result.stderr)


if __name__ == '__main__': unittest.main()
