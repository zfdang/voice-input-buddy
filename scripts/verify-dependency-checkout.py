#!/usr/bin/env python3
"""Reject local dependency edits; permit only the exact checked-in driver patch."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def verify(repository, patch=None, expected_revision=None):
    def git(*args, env=None):
        return subprocess.check_output(['git', '-C', str(repository), *args], env=env)
    if expected_revision is not None:
        head = git('rev-parse', 'HEAD').decode().strip()
        if head != expected_revision:
            raise ValueError(
                f'Unexpected HEAD revision in {repository}: {head} != {expected_revision}'
            )
    if git('ls-files', '--others', '--exclude-standard').strip():
        raise ValueError(f'Untracked files in dependency checkout: {repository}')
    actual = git('diff', '--binary', 'HEAD', '--')
    if not actual:
        return
    if patch is not None:
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / 'index'))
            git('read-tree', 'HEAD', env=environment)
            git('apply', '--cached', str(patch.resolve()), env=environment)
            expected = git('diff', '--cached', '--binary', 'HEAD', '--', env=environment)
        if actual == expected:
            return
    raise ValueError(f'Unexpected local changes in dependency checkout: {repository}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path, help='dependency Git checkout')
    parser.add_argument('patch', type=Path, nargs='?', help='permitted product patch')
    parser.add_argument('--expected-revision', help='required HEAD commit SHA')
    arguments = parser.parse_args()
    try:
        verify(arguments.repository, arguments.patch, arguments.expected_revision)
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
