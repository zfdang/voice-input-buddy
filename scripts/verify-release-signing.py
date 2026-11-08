#!/usr/bin/env python3
"""Require the pinned certificate and stable designated requirements on release bundles."""
from pathlib import Path
import subprocess
import sys

from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parent.parent
spec = spec_from_file_location('release_signing', ROOT / 'scripts/release-signing-keychain.py')
signing = module_from_spec(spec)
spec.loader.exec_module(signing)


def verify(bundle, identifier):
    identity = signing.fingerprint(signing.CERTIFICATE.read_bytes()).lower()
    requirement = f'identifier "{identifier}" and certificate leaf = H"{identity}"'
    signing.run(['codesign', '--verify', '--deep', '--strict', '-R=' + requirement, str(bundle)])
    result = subprocess.run(['codesign', '--display', '-r-', str(bundle)], capture_output=True, text=True)
    expected = {
        f'designated => identifier {identifier} and certificate leaf = H"{identity}"',
        f'designated => identifier "{identifier}" and certificate leaf = H"{identity}"',
    }
    lines = (result.stdout + result.stderr).splitlines()
    if result.returncode or not expected.intersection(lines):
        raise RuntimeError(f'Unexpected designated requirement for {identifier}')
    print(f'Verified stable signing identity: {identifier}')


if __name__ == '__main__':
    try:
        verify(ROOT / 'dist/Remote Buddy.app', 'com.zfdang.remote-buddy')
        verify(ROOT / 'dist/RemoteBuddyMic.driver', 'com.zfdang.remote-buddy.mic')
    except RuntimeError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
