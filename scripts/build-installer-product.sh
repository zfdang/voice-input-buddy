#!/bin/bash
# Wrap a component in Installer's standard pre-install Read Me flow.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/architecture.sh"
component="${1:?Component package is required}"
output="${2:?Output package is required}"
# This helper also runs before the first Swift build in a fresh checkout.
work="$(mktemp -d "${TMPDIR:-/tmp}/remote-buddy-installer.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$component" "$work/RemoteBuddyPayload.pkg"
productbuild --synthesize --package "$work/RemoteBuddyPayload.pkg" "$work/Distribution.xml"
python3 - "$work/Distribution.xml" "$BUILD_ARCH" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
options = root.find('options')
if options is None:
    options = ET.SubElement(root, 'options')
options.set('hostArchitectures', sys.argv[2])
ET.SubElement(root, 'title').text = 'Remote Buddy'
ET.SubElement(root, 'readme', {'file': 'ReadMe.html'})
# Synthesized package URLs must resolve inside package-path, not a temp path.
for ref in root.findall('pkg-ref'):
    if ref.text and ref.text.strip():
        ref.text = 'RemoteBuddyPayload.pkg'
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
productbuild --distribution "$work/Distribution.xml" --resources "$root/scripts/installer-resources" \
    --package-path "$work" "$output"
