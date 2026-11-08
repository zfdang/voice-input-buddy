#!/usr/bin/env python3
"""Validate both feed files belong to the latest published release before deployment."""
import base64
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'

def verify(directory, release):
    tag = release['tagName']
    names = {asset['name'] for asset in release['assets']}
    for architecture in ['arm64', 'intel']:
        path = directory / f'appcast-{architecture}.xml'
        if path.stat().st_size > 256 * 1024:
            raise ValueError('Oversized update feed')
        item = ET.parse(path).find('channel/item')
        package = f'Remote_Buddy_{tag}_macOS_{architecture}.pkg'
        if item is None or item.findtext('title') != tag or package not in names:
            raise ValueError('Feed does not match the latest release')
        enclosure = item.find('enclosure')
        expected = f'https://github.com/zfdang/voice-input-buddy/releases/download/{tag}/{package}'
        if enclosure is None or enclosure.get('url') != expected:
            raise ValueError('Unexpected package destination')
        if len(base64.b64decode(enclosure.get(f'{{{SPARKLE}}}edSignature', ''), validate=True)) != 64:
            raise ValueError('Missing update signature')
        version = item.findtext(f'{{{SPARKLE}}}version', '')
        if not version.isdigit() or int(version) <= 0 or int(version) % 1000 != int(tag.rsplit('.', 1)[1]):
            raise ValueError('Mismatched build version')
        if architecture == 'arm64' and item.findtext(f'{{{SPARKLE}}}hardwareRequirements') != 'arm64':
            raise ValueError('Missing Apple Silicon requirement')

if __name__ == '__main__':
    verify(Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()))
    print('Verified latest published update feeds for both architectures.')
