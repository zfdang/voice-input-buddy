#!/usr/bin/env python3
"""Check every screenshot used by setup is included in an app resource directory."""
import re
import struct
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
resources = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Resources'
# Check declarations before plist parsing, which silently collapses duplicate keys.
for strings in sorted(resources.glob('*.lproj/Localizable.strings')):
    keys = re.findall(r'^\s*"([^"\n]+)"\s*=', strings.read_text(), re.MULTILINE)
    seen = set()
    for key in keys:
        assert key not in seen, f'Duplicate localization key {key}: {strings}'
        seen.add(key)
app_sources = root / 'Sources/VoiceInputBuddy'
assert list((app_sources / 'Onboarding').rglob('*.swift')), 'No onboarding sources found; resource checks cannot be skipped'
setup_sources = sorted(app_sources.rglob('*.swift'))
source = '\n'.join(path.read_text() for path in setup_sources)

# Verify that all statically referenced localization keys exist in every strings file.
referenced_keys = set()
referenced_keys.update(re.findall(r'titleKey:\s*"([\w\.-]+)"', source))
referenced_keys.update(re.findall(r'detailKey:\s*"([\w\.-]+)"', source))
referenced_keys.update(re.findall(r'localization\.text\("([\w\.-]+)"\)', source))
referenced_keys.update(re.findall(r'LocalizedMessage\(\s*"([\w\.-]+)"', source))
for strings in sorted(resources.glob('*.lproj/Localizable.strings')):
    keys = set(re.findall(r'^\s*"([^"\n]+)"\s*=', strings.read_text(), re.MULTILINE))
    missing = [k for k in sorted(referenced_keys) if k not in keys]
    assert not missing, f'Missing referenced localization keys in {strings}: {missing}'

names = set(re.findall(r'\.screenshot\("([\w-]+)"\)', source))
names.update(re.findall(r'onboardingGuideScreenshot\(\s*resourceName: "([\w-]+)"', source))
files = []
def image_path(name, appearance):
    return next((path for extension in ('jpg', 'jpeg', 'png')
                 if (path := resources / 'Onboarding' / f'{name}-{appearance}.{extension}').exists()), None)

def dimensions(path):
    data = path.read_bytes()
    if path.suffix == '.png':
        assert data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) >= 24, f'Invalid PNG: {path}'
        return struct.unpack('>II', data[16:24])
    assert data[:2] == b'\xff\xd8', f'Invalid JPEG: {path}'
    offset = 2
    while offset < len(data):
        assert data[offset] == 0xff, f'Invalid JPEG marker: {path}'
        while offset < len(data) and data[offset] == 0xff:
            offset += 1
        assert offset < len(data), f'Truncated JPEG: {path}'
        marker = data[offset]
        offset += 1
        if marker in (0xda, 0xd9):
            break
        if marker == 0x01 or 0xd0 <= marker <= 0xd8:
            continue
        assert offset + 2 <= len(data), f'Truncated JPEG: {path}'
        length = struct.unpack('>H', data[offset:offset + 2])[0]
        assert length >= 2 and offset + length <= len(data), f'Invalid JPEG segment: {path}'
        if marker in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf):
            assert length >= 8, f'Truncated JPEG frame: {path}'
            height, width = struct.unpack('>HH', data[offset + 3:offset + 7])
            return width, height
        offset += length
    raise AssertionError(f'JPEG has no image dimensions: {path}')

for name in sorted(names):
    light = image_path(name, 'light')
    assert light is not None, f'Missing light screenshot: {name}'
    files.append(light)
    dark = image_path(name, 'dark')
    # New local captures are light only; the view falls back to that real capture.
    if dark is not None or name not in {'doubao-input-microphone', 'weixin-input-microphone', 'voicecursor-setting-fn', 'voicecursor-setting-mic', 'macos-dictation-enable', 'macos-dictation-shortcut', 'macos-dictation-microphone'}:
        assert dark is not None, f'Missing dark screenshot: {name}'
        files.append(dark)
# Product catalog resources are required even while adapters remain planned.
catalog = (app_sources / 'Devices/RemoteSetupDevice.swift').read_text()
illustrations = set(re.findall(r'return "(\w+Illustration)"', catalog))
assert illustrations, 'No product catalog illustrations found'
files.extend(resources / f'{name}.png' for name in sorted(illustrations))
for path in files:
    width, height = dimensions(path)
    assert width > 0 and height > 0, f'Empty image: {path}'
print(f'Verified {len(files)} setup and device images in {resources}')
