#!/usr/bin/env python3
"""Exercise identity validation, secret redaction and CI keychain cleanup."""
import base64
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release_signing', ROOT / 'scripts/release-signing-keychain.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
spec = importlib.util.spec_from_file_location('verify_signing', ROOT / 'scripts/verify-release-signing.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class ReleaseSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        cls.root = Path(cls.fixture.name)
        cls.certificate = cls.root / 'certificate.pem'
        cls.archive = cls.root / 'identity.p12'
        subprocess.run(['openssl', 'req', '-new', '-x509', '-newkey', 'rsa:2048',
                        '-nodes', '-days', '1', '-subj', '/CN=Signing Test Fixture',
                        '-keyout', str(cls.root / 'key.pem'), '-out', str(cls.certificate)],
                       check=True, capture_output=True)
        subprocess.run(['openssl', 'pkcs12', '-export', '-inkey', str(cls.root / 'key.pem'),
                        '-in', str(cls.certificate), '-out', str(cls.archive), '-passout', 'stdin'],
                       input=b'fixture-password\n', check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name) / 'signing'
        self.environment = Path(directory.name) / 'github-env'
        self.commands = []
        self.fail_import = False
        self.fail_delete = False
        self.fail_restore = False
        self.real_run = signing.run
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(signing, 'CERTIFICATE', self.certificate).start()
        mock.patch.dict(os.environ, {
            'MACOS_SIGNING_P12_BASE64': base64.b64encode(self.archive.read_bytes()).decode(),
            'MACOS_SIGNING_P12_PASSWORD': 'fixture-password',
            'GITHUB_ENV': str(self.environment),
        }).start()
        mock.patch.object(signing, 'run', side_effect=self.run_command).start()

    def run_command(self, arguments, **kwargs):
        if arguments[0] == 'openssl':
            return self.real_run(arguments, **kwargs)
        self.commands.append(arguments)
        if arguments[1] == 'list-keychains' and '-s' not in arguments:
            return b'    "/fixture/login.keychain-db"\n    "/fixture/system.keychain"\n'
        if arguments[1] == 'import' and self.fail_import:
            raise RuntimeError('security failed (exit 1)')
        if arguments[1] == 'delete-keychain' and self.fail_delete:
            raise RuntimeError('fixture-password must not appear in warnings')
        if arguments[1] == 'list-keychains' and '-s' in arguments and self.fail_restore:
            raise RuntimeError('fixture-password must not appear in warnings')
        return b''

    def test_setup_reuses_identity_without_trust_changes_and_cleanup_restores_search_list(self):
        signing.setup(self.directory)
        identity = signing.fingerprint(self.certificate.read_bytes())
        environment = self.environment.read_text()
        self.assertIn('CODE_SIGN_IDENTITY=' + identity, environment)
        self.assertNotIn('fixture-password', environment)
        self.assertFalse((self.directory / 'identity.p12').exists())
        self.assertFalse(any(command[1] in ('add-trusted-cert', 'trust-settings-import') for command in self.commands))
        signing.cleanup(self.directory)
        self.assertIn(['security', 'list-keychains', '-d', 'user', '-s',
                       '/fixture/login.keychain-db', '/fixture/system.keychain'], self.commands)
        self.assertEqual(self.commands[-1][1], 'delete-keychain')
        self.assertFalse((self.directory / 'state.json').exists())
        signing.cleanup(self.directory)  # always() is safe even after setup already cleaned up.

    def test_wrong_certificate_fails_before_any_keychain_changes(self):
        mock.patch.object(signing, 'CERTIFICATE', ROOT / 'scripts/signing/release-certificate.pem').start()
        with self.assertRaisesRegex(RuntimeError, 'does not match'):
            signing.setup(self.directory)
        self.assertEqual(self.commands, [])
        self.assertFalse((self.directory / 'identity.p12').exists())
        self.assertFalse(self.environment.exists())

    def test_repeated_setup_preserves_active_keychain_and_exported_environment(self):
        signing.setup(self.directory)
        state = (self.directory / 'state.json').read_bytes()
        environment = self.environment.read_bytes()
        commands = list(self.commands)
        with self.assertRaisesRegex(RuntimeError, 'already prepared'):
            signing.setup(self.directory)
        self.assertEqual((self.directory / 'state.json').read_bytes(), state)
        self.assertEqual(self.environment.read_bytes(), environment)
        self.assertEqual(self.commands, commands)
        self.assertFalse((self.directory / 'identity.p12').exists())

    def test_setup_can_retry_after_failure_before_identity_creation(self):
        with mock.patch.object(signing, 'CERTIFICATE', ROOT / 'scripts/signing/release-certificate.pem'):
            with self.assertRaisesRegex(RuntimeError, 'does not match'):
                signing.setup(self.directory)
        self.assertTrue(self.directory.exists())
        signing.setup(self.directory)
        self.assertTrue((self.directory / 'state.json').exists())
        self.assertEqual(self.environment.read_text().count('CODE_SIGN_IDENTITY='), 1)

    def test_missing_secrets_never_falls_back_to_adhoc_signing(self):
        mock.patch.dict(os.environ, {'MACOS_SIGNING_P12_PASSWORD': ''}).start()
        with self.assertRaisesRegex(RuntimeError, 'Both macOS signing secrets are required'):
            signing.setup(self.directory)
        self.assertFalse(self.directory.exists())
        self.assertEqual(self.commands, [])

    def test_import_failure_removes_keychain_and_archive(self):
        self.fail_import = True
        with self.assertRaisesRegex(RuntimeError, 'security failed'):
            signing.setup(self.directory)
        self.assertEqual(self.commands[-1][1], 'delete-keychain')
        self.assertFalse((self.directory / 'identity.p12').exists())
        self.assertFalse(self.environment.exists())

    def test_cleanup_failure_does_not_fail_job_and_retains_state_for_retry(self):
        self.directory = self.directory.with_name('remote-buddy-signing')
        signing.setup(self.directory)
        self.fail_delete = True
        warnings = io.StringIO()
        with mock.patch.dict(os.environ, {'RUNNER_TEMP': str(self.directory.parent)}), \
                mock.patch.object(signing.sys, 'argv', ['release-signing-keychain.py', 'cleanup']), \
                contextlib.redirect_stderr(warnings):
            self.assertEqual(signing.main(), 0)
        self.assertIn('delete the temporary signing keychain', warnings.getvalue())
        self.assertNotIn('fixture-password', warnings.getvalue())
        self.assertTrue((self.directory / 'state.json').exists())
        self.fail_delete = False
        signing.cleanup(self.directory)
        self.assertFalse((self.directory / 'state.json').exists())

    def test_restore_failure_still_attempts_keychain_deletion(self):
        signing.setup(self.directory)
        self.fail_restore = True
        with contextlib.redirect_stderr(io.StringIO()):
            signing.cleanup(self.directory)
        self.assertEqual(self.commands[-1][1], 'delete-keychain')
        self.assertTrue((self.directory / 'state.json').exists())

    def test_cleanup_failure_does_not_mask_setup_error(self):
        self.fail_import = True
        self.fail_delete = True
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, '^security failed \\(exit 1\\)$'):
                signing.setup(self.directory)
        self.assertFalse((self.directory / 'identity.p12').exists())
        self.assertFalse(self.environment.exists())

    def test_failed_commands_do_not_expose_passwords_or_tool_output(self):
        result = subprocess.CompletedProcess(['security'], 1, stdout=b'private-key', stderr=b'fixture-password')
        with mock.patch.object(signing.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, '^security failed \\(exit 1\\)$'):
                self.real_run(['security', 'import', '-P', 'fixture-password'])

    def test_bundle_signing_passes_explicit_keychain_and_preserves_paths_with_spaces(self):
        tool = self.directory.parent / 'codesign'
        output = self.directory.parent / 'arguments'
        tool.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$SIGNING_FIXTURE_OUTPUT"\n')
        tool.chmod(0o755)
        environment = {**os.environ, 'PATH': str(tool.parent) + os.pathsep + os.environ['PATH'],
                       'CODE_SIGN_IDENTITY': 'fixed-identity', 'CODE_SIGN_KEYCHAIN': '/fixture/keychain with spaces',
                       'SIGNING_FIXTURE_OUTPUT': str(output)}
        app = self.directory.parent / 'App With Spaces.app'
        app.mkdir()
        subprocess.run(['bash', str(ROOT / 'scripts/sign-bundle.sh'), str(app)],
                       env=environment, check=True, capture_output=True)
        self.assertEqual(output.read_text().splitlines(), ['--force', '--sign', 'fixed-identity',
                         '--keychain', '/fixture/keychain with spaces', str(app)])

    def test_verification_accepts_fixed_identity_and_rejects_content_hash_identity(self):
        identity = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
        normalized_identity = identity.lower()
        identifier = 'com.zfdang.remote-buddy'
        with mock.patch.object(verification.signing, 'fingerprint', return_value=identity), \
                mock.patch.object(verification.signing, 'run') as verify_command:
            for label in [identifier, '"' + identifier + '"']:
                output = f'designated => identifier {label} and certificate leaf = H"{normalized_identity}"\n'
                result = subprocess.CompletedProcess(['codesign'], 0, stdout=output, stderr='')
                with mock.patch.object(verification.subprocess, 'run', return_value=result):
                    verification.verify(Path('/fixture/app'), identifier)
                self.assertIn('-R=identifier "' + identifier + '" and certificate leaf = H"' + normalized_identity + '"',
                              verify_command.call_args.args[0])
            result = subprocess.CompletedProcess(['codesign'], 0, stdout='designated => cdhash H"abc"\n', stderr='')
            with mock.patch.object(verification.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(RuntimeError, 'Unexpected designated requirement'):
                    verification.verify(Path('/fixture/app'), identifier)


if __name__ == '__main__':
    unittest.main()
