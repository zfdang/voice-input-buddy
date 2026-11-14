#!/usr/bin/env python3
"""Generate the feed for the exact signed combined package published in a release."""
import argparse
import base64
from pathlib import Path
import re
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)

def generate(package, tag, version, signature, output, changes=None):
    if not re.fullmatch(r'v\d{2}-\d{2}-\d{2}\.\d{3}', tag):
        raise ValueError('Invalid release tag')
    if not version.isdigit() or int(version) <= 0 or int(tag.rsplit('.', 1)[1]) != int(version) % 1000:
        raise ValueError('Invalid bundle version')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid Ed25519 signature')
    match = re.fullmatch(r'Remote_Buddy_' + re.escape(tag) + r'_macOS_(arm64|intel)\.pkg', package.name)
    if not match:
        raise ValueError('Package must specify arm64 or intel')
    architecture = match.group(1)
    expected = package.name
    if package.stat().st_size == 0:
        raise ValueError('Package must match release tag and be nonempty')
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Remote Buddy'
    ET.SubElement(channel, 'link').text = 'https://remote.zfdang.com/'
    ET.SubElement(channel, 'description').text = 'Stable macOS updates'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = tag
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = tag
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = '14.0'
    if architecture == 'arm64':
        ET.SubElement(item, f'{{{SPARKLE}}}hardwareRequirements').text = 'arm64'
    ET.SubElement(item, 'description').text = changes or '此版本未提供更新摘要。'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/zfdang/remote-buddy/releases/download/{tag}/{expected}',
        'length': str(package.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature, f'{{{SPARKLE}}}installationType': 'package'})
    ET.indent(rss)
    ET.ElementTree(rss).write(output, encoding='utf-8', xml_declaration=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['package', 'tag', 'version', 'signature', 'output']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--changes-file', type=Path, required=True)
    args = parser.parse_args()
    generate(Path(args.package), args.tag, args.version, args.signature, args.output,
             args.changes_file.read_text(encoding='utf-8'))
