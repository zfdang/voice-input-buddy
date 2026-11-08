#!/usr/bin/env python3
"""Build and inspect an inert package; never install it or restart Core Audio."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent

@unittest.skipUnless(all(shutil.which(t) for t in ('pkgbuild', 'productbuild', 'pkgutil')), 'macOS packaging tools required')
class InstallerNoticeTests(unittest.TestCase):
    def test_notice_precedes_install_and_payload_identity_survives(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            # Reproduce a fresh CI checkout before Swift creates .build.
            checkout = work / 'fresh checkout'
            scripts = checkout / 'scripts'
            scripts.mkdir(parents=True)
            helper = scripts / 'build-installer-product.sh'
            shutil.copy2(ROOT / 'scripts/build-installer-product.sh', helper)
            shutil.copy2(ROOT / 'scripts/architecture.sh', scripts / 'architecture.sh')
            shutil.copytree(ROOT / 'scripts/installer-resources', scripts / 'installer-resources')
            self.assertFalse((checkout / '.build').exists())
            component, product = work / 'component.pkg', work / 'product.pkg'
            subprocess.run(['pkgbuild', '--nopayload', '--identifier', 'com.example.inert-test',
                            '--version', '1.0', str(component)], check=True)
            subprocess.run([str(helper), str(component), str(product)],
                           env={**os.environ, 'BUILD_ARCH': 'arm64'}, check=True)
            subprocess.run(['pkgutil', '--expand-full', str(product), str(work / 'expanded')],
                           check=True)
            self.assertFalse((checkout / '.build').exists())
            expanded = work / 'expanded'
            distribution = ET.parse(expanded / 'Distribution').getroot()
            self.assertEqual(distribution.find('options').get('hostArchitectures'), 'arm64')
            self.assertEqual(distribution.find('readme').get('file'), 'ReadMe.html')
            notice = (expanded / 'Resources/ReadMe.html').read_text()
            self.assertIn('all system playback and recording', notice)
            self.assertIn('系统全部播放和录音', notice)
            self.assertIn('not notarized', notice)
            intel_product = work / 'intel.pkg'
            subprocess.run([str(helper), str(component), str(intel_product)],
                           env={**os.environ, 'BUILD_ARCH': 'x86_64'}, check=True)
            subprocess.run(['pkgutil', '--expand', str(intel_product), str(work / 'intel')], check=True)
            self.assertEqual(ET.parse(work / 'intel/Distribution').getroot().find('options').get('hostArchitectures'), 'x86_64')
            info = ET.parse(expanded / 'RemoteBuddyPayload.pkg/PackageInfo').getroot()
            self.assertEqual(info.get('identifier'), 'com.example.inert-test')
            self.assertEqual(info.get('version'), '1.0')

if __name__ == '__main__':
    unittest.main()
