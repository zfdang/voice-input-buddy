#!/usr/bin/env python3
"""Import the fixed release identity into an ephemeral CI keychain, without trust changes."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

CERTIFICATE = Path(__file__).resolve().parent / 'signing/release-certificate.pem'


def run(arguments, *, input=None):
    result = subprocess.run(arguments, input=input, capture_output=True)
    if result.returncode:
        # Commands may carry passwords. Never print their arguments or output.
        raise RuntimeError(f'{Path(arguments[0]).name} failed (exit {result.returncode})')
    return result.stdout


def fingerprint(certificate):
    der = run(['openssl', 'x509', '-outform', 'DER'], input=certificate)
    return hashlib.sha1(der).hexdigest().upper()


def cleanup(directory):
    state_file = directory / 'state.json'
    if not state_file.exists():
        return
    try:
        state = json.loads(state_file.read_text())
        restore = ['security', 'list-keychains', '-d', 'user', '-s', *state['search_list']]
        delete = ['security', 'delete-keychain', state['keychain']]
    except (OSError, ValueError, KeyError, TypeError):
        print('Warning: signing cleanup state could not be read; runner disposal will remove temporary material.', file=sys.stderr)
        return
    failed = False
    for command, operation in [(restore, 'restore the keychain search list'),
                               (delete, 'delete the temporary signing keychain')]:
        try:
            run(command)
        except Exception:
            failed = True
            # Cleanup is best effort on an ephemeral runner, with no sensitive output.
            print(f'Warning: could not {operation}; cleanup can be retried before runner disposal.', file=sys.stderr)
    if failed:
        return  # Preserve state for retry, without failing a completed build.
    try:
        state_file.unlink()
    except OSError:
        print('Warning: signing cleanup state could not be removed; runner disposal will remove it.', file=sys.stderr)


def setup(directory):
    state_file = directory / 'state.json'
    if state_file.exists():
        raise RuntimeError('Release signing is already prepared; refusing to replace the active keychain')
    encoded = os.environ.get('MACOS_SIGNING_P12_BASE64', '')
    password = os.environ.get('MACOS_SIGNING_P12_PASSWORD', '')
    if not encoded or not password:
        raise RuntimeError('Both macOS signing secrets are required for production releases')
    archive = base64.b64decode(encoded, validate=True)
    directory.mkdir(mode=0o700, exist_ok=True)
    archive_file = directory / 'identity.p12'
    archive_file.write_bytes(archive)
    archive_file.chmod(0o600)
    keychain = str(directory / 'release.keychain-db')
    try:
        certificate = run(['openssl', 'pkcs12', '-in', str(archive_file), '-clcerts',
                           '-nokeys', '-passin', 'stdin'], input=(password + '\n').encode())
        identity = fingerprint(CERTIFICATE.read_bytes())
        if fingerprint(certificate) != identity:
            raise RuntimeError('Signing secret does not match the pinned release certificate')
        search_list = [line.strip().strip('"') for line in
                       run(['security', 'list-keychains', '-d', 'user']).decode().splitlines()]
        keychain_password = secrets.token_hex(32)
        state_file.write_text(json.dumps({'keychain': keychain, 'search_list': search_list}))
        state_file.chmod(0o600)
        run(['security', 'create-keychain', '-p', keychain_password, keychain])
        run(['security', 'set-keychain-settings', '-lut', '21600', keychain])
        run(['security', 'unlock-keychain', '-p', keychain_password, keychain])
        run(['security', 'import', str(archive_file), '-k', keychain, '-P', password,
             '-T', '/usr/bin/codesign'])
        run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
             '-s', '-k', keychain_password, keychain])
        # codesign also consults the search list for identity lookup and chain construction,
        # even when the signing command explicitly specifies --keychain.
        # This does not install a trusted root or change any certificate trust setting.
        run(['security', 'list-keychains', '-d', 'user', '-s', keychain, *search_list])
        with open(os.environ['GITHUB_ENV'], 'a') as environment:
            environment.write(f'CODE_SIGN_IDENTITY={identity}\nCODE_SIGN_KEYCHAIN={keychain}\n')
        print(f'Prepared fixed release signing identity: {identity}')
    except Exception:
        cleanup(directory)
        raise
    finally:
        archive_file.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['setup', 'cleanup'])
    args = parser.parse_args()
    directory = Path(os.environ['RUNNER_TEMP']) / 'remote-buddy-signing'
    try:
        (setup if args.action == 'setup' else cleanup)(directory)
    except Exception as error:
        # Only messages created by this script are safe to expose.
        print(str(error) if isinstance(error, RuntimeError) else 'Release signing setup/cleanup failed', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
