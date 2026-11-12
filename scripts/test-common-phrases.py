#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('phrases', root / 'scripts/generate-common-phrases.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = (root / 'Resources/CommonPhrases/built-in.md').read_text()

class PhraseTests(unittest.TestCase):
    def test_resource(self):
        result = module.generate(source)
        self.assertEqual(len(result['entries']), 12)
        self.assertEqual(result['bindings']['ok'], 'builtin-001')
        self.assertEqual(result['entries'][2]['text'], '看不懂，说清楚一点')
    def test_chromecast_keys_have_defaults(self):
        result = module.generate(source)
        self.assertEqual(len(result['bindings']), 11)
        self.assertEqual(result['bindings']['home'], 'builtin-006')
        self.assertEqual(result['bindings']['mute'], 'builtin-007')
        self.assertEqual(result['bindings']['input'], 'builtin-011')
    def test_entries_keep_only_original_chinese_content_with_neutral_fields(self):
        result = module.generate(source)
        self.assertEqual(result['schemaVersion'], 2)
        self.assertEqual(result['entries'][0], {'id': 'builtin-001', 'text': '好的', 'label': '好的'})
        self.assertTrue(all(set(p) == {'id', 'text', 'label'} for p in result['entries']))
        self.assertEqual(len(set(p['id'] for p in result['entries'])), 12)
        self.assertEqual(result['builtInIDs'], [p['id'] for p in result['entries']])
    def test_source_changes_flow_to_json(self):
        result = module.generate(source.replace('好的', '没问题'))
        self.assertEqual(result['entries'][0]['text'], '没问题')
    def test_bad_defaults_fail(self):
        for bad in [source.replace('| OK | 1 |', '| OK | 99 |'),
                    source.replace('| 左 | 2 |', '| OK | 2 |'),
                    source.replace('| 上 | 3 | 看不懂，说清楚一点 |', '| 上 | 3 | 错误 |'),
                    source.replace('| 静音 | 7 |', '| 主页 | 7 |')]:
            with self.assertRaises(ValueError): module.generate(bad)
    def test_bad_phrase_rows_fail(self):
        for bad in [source.replace('| 2 | 继续 |', '| 1 | 继续 |'),
                    source.replace('| 1 | 好的 | 好的 |', '| 1 | 好的 | |')]:
            with self.assertRaises(ValueError): module.generate(bad)

unittest.main()
