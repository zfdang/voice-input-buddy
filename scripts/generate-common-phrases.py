#!/usr/bin/env python3
"""Generate validated bundled phrases from the single editable Markdown source."""
import json
from pathlib import Path
import sys


def generate(text):
    section = None
    phrases = []
    defaults = {}
    buttons = {'OK': 'ok', '左': 'left', '上': 'up', '右': 'right', '下': 'down',
               '主页': 'home', '静音': 'mute', 'YouTube': 'youtube', 'Netflix': 'netflix',
               '电源': 'power', '信源': 'input'}
    for line in text.splitlines():
        if line.startswith('## '):
            section = line[3:].strip()
        if not line.startswith('|'):
            continue
        cells = [value.strip() for value in line.strip().strip('|').split('|')]
        if section == '常用语表':
            if cells[0] == '#' or all(set(c) <= set('-:') for c in cells):
                continue
            if len(cells) != 3 or not all(cells) or not cells[0].isdigit() or int(cells[0]) != len(phrases) + 1:
                raise ValueError('Phrase rows must contain three nonempty columns and consecutive numbers')
            number, content, label = cells
            if len(content) > 4000 or len(label) > 80:
                raise ValueError('Phrase text or label is too long')
            phrases.append(dict(id=f'builtin-{int(number):03}', text=content, label=label))
        elif section == '默认键位':
            if cells[0] == '按键' or all(set(c) <= set('-:') for c in cells):
                continue
            if len(cells) != 3 or cells[0] not in buttons or not cells[1].isdigit():
                raise ValueError('Invalid default binding row')
            button = buttons[cells[0]]
            index = int(cells[1]) - 1
            if button in defaults or index not in range(len(phrases)) or cells[2] != phrases[index]['text']:
                raise ValueError('Duplicate, unknown or inconsistent default binding')
            defaults[button] = phrases[index]['id']
    if not len(buttons) <= len(phrases) <= 500 or set(defaults) != set(buttons.values()) \
            or len(set(defaults.values())) != len(buttons):
        raise ValueError('Missing phrases or defaults')
    return dict(schemaVersion=2, entries=phrases, bindings=defaults, builtInIDs=[p['id'] for p in phrases])


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: generate-common-phrases.py INPUT.md OUTPUT.json')
    source, destination = map(Path, sys.argv[1:])
    destination.write_text(json.dumps(generate(source.read_text()), ensure_ascii=False, indent=2) + '\n')
