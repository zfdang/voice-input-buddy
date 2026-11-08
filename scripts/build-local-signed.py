#!/usr/bin/env python3
"""Build local dist artifacts with the existing, pinned signing identity."""
import argparse
import base64
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def build(identity_directory, configuration):
    archive = identity_directory / 'release-signing.p12'
    password = identity_directory / 'password.txt'
    if not archive.is_file() or not password.is_file():
        raise RuntimeError('The existing signing identity and password are required; no new identity was generated.')
    temporary = Path(tempfile.mkdtemp(prefix='remote-buddy-local-signing-'))
    environment_file = temporary / 'environment'
    # Use Apple's PKCS#12-compatible tools rather than an unrelated Python env's OpenSSL.
    local_environment = dict(os.environ, PATH='/usr/bin:' + os.environ.get('PATH', ''))
    for key in ('MACOS_SIGNING_P12_BASE64', 'MACOS_SIGNING_P12_PASSWORD'):
        local_environment.pop(key, None)
    setup_environment = dict(local_environment,
        RUNNER_TEMP=str(temporary), GITHUB_ENV=str(environment_file),
        MACOS_SIGNING_P12_BASE64=base64.b64encode(archive.read_bytes()).decode(),
        MACOS_SIGNING_P12_PASSWORD=password.read_text().strip())
    helper = ROOT / 'scripts/release-signing-keychain.py'
    cleanup_environment = dict(local_environment, RUNNER_TEMP=str(temporary))
    try:
        subprocess.run([sys.executable, str(helper), 'setup'], env=setup_environment, check=True)
        build_environment = dict(local_environment, CONFIGURATION=configuration)
        # Signing credentials belong only to setup, never to compiler or package scripts.
        for key in ('MACOS_SIGNING_P12_BASE64', 'MACOS_SIGNING_P12_PASSWORD'):
            build_environment.pop(key, None)
        signing_environment = {}
        for line in environment_file.read_text().splitlines():
            key, value = line.split('=', 1)
            if key not in ('CODE_SIGN_IDENTITY', 'CODE_SIGN_KEYCHAIN') or not value:
                raise RuntimeError('Unexpected signing environment field')
            signing_environment[key] = value
        if signing_environment.keys() != {'CODE_SIGN_IDENTITY', 'CODE_SIGN_KEYCHAIN'}:
            raise RuntimeError('Fixed signing identity was not prepared')
        build_environment.update(signing_environment)
        for script in ('build-app.sh', 'build-driver.sh'):
            subprocess.run(['bash', str(ROOT / 'scripts' / script)],
                           cwd=ROOT, env=build_environment, check=True)
        subprocess.run([sys.executable, str(ROOT / 'scripts/verify-release-signing.py')],
                       cwd=ROOT, env=build_environment, check=True)
        subprocess.run(['bash', str(ROOT / 'scripts/build-driver-package.sh')],
                       cwd=ROOT, env=build_environment, check=True)
    finally:
        subprocess.run([sys.executable, str(helper), 'cleanup'], env=cleanup_environment, check=False)
        if (temporary / 'remote-buddy-signing/state.json').exists():
            print(f'Signing cleanup needs a retry; recovery state retained at {temporary}', file=sys.stderr)
        else:
            shutil.rmtree(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity-directory', type=Path,
        default=Path.home() / 'Library/Application Support/RemoteBuddySigning')
    parser.add_argument('--configuration', choices=('debug', 'release'), default='debug')
    arguments = parser.parse_args()
    try:
        build(arguments.identity_directory, arguments.configuration)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError):
        # Exception details or child environments can contain credentials.
        print('Fixed-identity local build failed; signing credentials were not printed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
