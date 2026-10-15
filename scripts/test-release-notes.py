#!/usr/bin/env python3
"""Exercise real merge history and publication boundaries for release changes."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('notes', Path(__file__).with_name('generate-release-notes.py'))
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)

class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.commit('chore: initial repository')
        self.git('tag', 'v26-10-10.001')
        self.base = self.git('rev-parse', 'HEAD')
        self.original_git = notes.git
        notes.git = self.git
        self.addCleanup(lambda: setattr(notes, 'git', self.original_git))

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True, stderr=subprocess.PIPE).strip()

    def commit(self, message):
        self.git('commit', '-q', '--allow-empty', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def release(self, tag='v26-10-10.001', **fields):
        return {'tag_name': tag, 'draft': False, 'prerelease': False, 'published_at': '2026-10-10T00:00:00Z', **fields}

    def render(self, releases):
        return notes.generate('HEAD', releases, 'example/project')

    def merge_feature(self):
        self.git('switch', '-q', '-c', 'feature')
        self.commit('feat: internal transport implementation')
        self.commit('test: internal protocol tests')
        self.git('switch', '-q', 'main')
        self.git('merge', '-q', '--no-ff', 'feature', '-m', 'Merge pull request #2 from example/feature\n\nfeat(devices): add G9N9N support')

    def test_merge_is_one_change_and_internal_commits_are_not_duplicated(self):
        self.merge_feature()
        markdown, summary = self.render([[self.release()]])
        self.assertEqual(summary.count('add G9N9N support'), 1)
        self.assertNotIn('internal transport', summary)
        self.assertNotIn('initial repository', summary)
        self.assertIn('/pull/2', markdown)
        self.assertIn('- [新增] add G9N9N support', markdown)

    def test_one_list_preserves_commit_order_across_interleaved_types(self):
        changes = [
            ('fix: first correction', '[修复] first correction'),
            ('feat: new feature', '[新增] new feature'),
            ('docs: usage guide', '[文档] usage guide'),
            ('fix: second correction', '[修复] second correction'),
            ('perf: faster startup', '[改进] faster startup'),
            ('test: protocol coverage', '[构建与测试] protocol coverage'),
            ('plain commit title', '[其他变化] plain commit title'),
        ]
        for message, _ in changes:
            self.commit(message)
        markdown, summary = self.render([self.release()])
        for output in [markdown, summary]:
            lines = output.splitlines()
            bullets = [line for line in lines if line.startswith('- ')]
            self.assertEqual(len(bullets), len(changes))
            for line, (_, expected) in zip(bullets, changes):
                self.assertTrue(line.startswith('- ' + expected + ' ('), line)
            self.assertFalse(any(line.startswith('#') for line in lines))
        self.assertIn('[查看完整变化]', markdown)
        self.assertNotIn('安装与签名', markdown)
        self.assertNotIn('对应源码与依赖', markdown)

    def test_nearest_published_release_wins_over_api_order_and_unpublished_tags(self):
        self.commit('fix: old issue')
        self.git('tag', 'v26-10-11.002')
        self.commit('feat: unpublished change')
        self.git('tag', 'v26-10-12.003')
        self.commit('fix: latest correction')
        markdown, summary = self.render([self.release(), self.release('v26-10-11.002')])
        self.assertIn('unpublished change', summary)
        self.assertIn('latest correction', summary)
        self.assertNotIn('old issue', summary)
        self.assertIn('/compare/v26-10-11.002...', markdown)

    def test_current_release_rerun_preserves_the_previous_range(self):
        self.commit('fix: current correction (#8)')
        before = self.render([self.release()])
        self.git('tag', 'v26-10-11.002')
        after = self.render([self.release('v26-10-11.002'), self.release()])
        self.assertEqual(before, after)
        self.assertIn('/pull/8', after[0])

    def test_draft_preview_future_and_side_branch_releases_are_not_baselines(self):
        self.git('switch', '-q', '-c', 'side')
        self.commit('feat: unrelated')
        self.git('tag', 'v26-10-12.010')
        self.git('switch', '-q', 'main')
        self.commit('fix: included correction')
        self.git('tag', 'v26-10-12.011')
        target = self.git('rev-parse', 'HEAD')
        self.commit('fix: future')
        self.git('tag', 'v26-10-12.012')
        releases = [self.release(), self.release('v26-10-12.010'), self.release('v26-10-12.012'),
                    self.release('v26-10-12.011', draft=True), self.release('v26-10-12.011', prerelease=True)]
        _, summary = notes.generate(target, releases, 'example/project')
        self.assertIn('included correction', summary)
        self.assertNotIn('unrelated', summary)
        self.assertNotIn('future', summary)

    def test_first_release_direct_commits_and_markdown_text(self):
        self.commit('fix: render <input> & [value] safely')
        markdown, summary = self.render([])
        self.assertIn('首次发布', markdown)
        self.assertIn('initial repository', summary)
        self.assertIn(r'\<input\>', markdown)
        self.assertIn('<input> & [value]', summary)
        self.assertIn('/commit/', markdown)

    def test_missing_published_tag_and_shallow_history_fail_closed(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.render([self.release('v26-10-12.099')])
        shallow = self.root / 'shallow'
        subprocess.run(['git', 'clone', '-q', '--depth', '1', self.root.as_uri(), str(shallow)], check=True)
        notes.git = lambda *args: subprocess.check_output(['git', '-C', str(shallow), *args], text=True).strip()
        with self.assertRaises(ValueError):
            self.render([])

    def test_workflow_uses_one_shared_artifact_for_release_and_appcast(self):
        workflow = Path(__file__).parent.parent / '.github/workflows/release.yml'
        text = workflow.read_text()
        self.assertNotIn('cat > release-notes.md', text)
        self.assertIn('name: release-changelog', text)
        self.assertIn('--notes-file release-notes.md', text)
        signer = Path(__file__).with_name('sign-release-update.sh').read_text()
        self.assertIn('--changes-file "$RELEASE_CHANGES_FILE"', signer)

if __name__ == '__main__':
    unittest.main()
