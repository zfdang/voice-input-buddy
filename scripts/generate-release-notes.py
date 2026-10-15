#!/usr/bin/env python3
"""Render changes since the nearest published stable first-parent release."""
import argparse
import json
from pathlib import Path
import re
import subprocess

TAG = re.compile(r'v\d{2}-\d{2}-\d{2}\.\d{3}\Z')
CONVENTIONAL = re.compile(r'^(feat|fix|perf|refactor|style|docs|test|build|ci|chore|revert)(?:\([^)]*\))?(!)?:\s*(.+)$')
TYPE_LABELS = {
    'feat': '新增', 'fix': '修复', 'revert': '修复',
    'perf': '改进', 'refactor': '改进', 'style': '改进', 'docs': '文档',
    'build': '构建与测试', 'ci': '构建与测试', 'test': '构建与测试',
    'chore': '构建与测试', 'other': '其他变化',
}


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def published_releases(payload):
    # gh api --paginate --slurp produces one list per page.
    releases = []
    for entry in payload:
        releases.extend(entry if isinstance(entry, list) else [entry])
    return [r for r in releases if r.get('published_at') and not r.get('draft') and not r.get('prerelease')
            and TAG.fullmatch(r.get('tag_name', ''))]


def generate(commit, releases, repository):
    if git('rev-parse', '--is-shallow-repository') != 'false':
        raise ValueError('Full Git history is required')
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', repository):
        raise ValueError('Invalid repository name')
    head = git('rev-parse', '--verify', commit + '^{commit}')
    chain = git('rev-list', '--first-parent', head).splitlines()
    distances = {sha: index for index, sha in enumerate(chain)}
    candidates = []
    for release in published_releases(releases):
        tag = release['tag_name']
        # Missing published tags are an incomplete checkout, not a first release.
        sha = git('rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}')
        distance = distances.get(sha)
        if distance is not None and distance > 0:
            candidates.append((distance, tag, sha))
    previous = min(candidates)[1] if candidates else None
    revision = f'{previous}..{head}' if previous else head
    commits = git('log', '--first-parent', '--reverse', '--format=%H', revision).splitlines()
    entries = []
    for sha in commits:
        lines = git('show', '-s', '--format=%B', sha).splitlines()
        subject = lines[0]
        merge = re.match(r'^Merge pull request #(\d+)\b', subject)
        if merge:
            title = next((line.strip() for line in lines[1:] if line.strip()), subject)
            number = merge.group(1)
        else:
            squash = re.search(r' \(#(\d+)\)$', subject)
            number = squash.group(1) if squash else None
            title = subject[:squash.start()] if squash else subject
        match = CONVENTIONAL.match(title)
        kind = match.group(1) if match else 'other'
        description = match.group(3) if match else title
        if match and match.group(2):
            description += '（不兼容变更）'
        reference = f'#{number}' if number else sha[:7]
        url = f'https://github.com/{repository}/' + (f'pull/{number}' if number else f'commit/{sha}')
        # Titles are text, not Markdown supplied by a contributor.
        escaped = re.sub(r'([\\`*_\[\]<>])', r'\\\1', description)
        entries.append((kind, description, escaped, reference, url))
    markdown, summary = [], []
    # Keep the oldest-to-newest commit order from git log, regardless of type.
    for kind, text, escaped, reference, url in entries:
        label = TYPE_LABELS[kind]
        markdown.append(f'- [{label}] {escaped} ([{reference}]({url}))')
        summary.append(f'- [{label}] {text} ({reference})')
    markdown.append('')
    if not entries:
        markdown = ['此版本没有新的提交变化。', '']
        summary = ['此版本没有新的提交变化。']
    if previous:
        markdown.append(f'[查看完整变化](https://github.com/{repository}/compare/{previous}...{head})')
    else:
        markdown.append('首次发布，以上为当前版本的全部提交变化。')
    markdown.append('')
    return '\n'.join(markdown), '\n'.join(summary).strip() + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--commit', required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--releases-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--summary-output', type=Path, required=True)
    args = parser.parse_args()
    markdown, summary = generate(args.commit, json.loads(args.releases_file.read_text()), args.repository)
    args.output.write_text(markdown, encoding='utf-8')
    args.summary_output.write_text(summary, encoding='utf-8')
