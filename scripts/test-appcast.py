#!/usr/bin/env python3
import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('appcast', Path(__file__).with_name('generate-appcast.py'))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)

class AppcastTests(unittest.TestCase):
    def test_shared_changes_are_preserved_as_xml_text_for_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / 'Remote_Buddy_v26-10-14.130_macOS_arm64.pkg'
            package.write_bytes(b'package')
            output = Path(directory) / 'appcast.xml'
            changes = '新增\n- add G9N9N support (#37)\n修复\n- handle <input> & microphone events\n'
            appcast.generate(package, 'v26-10-14.130', '130', base64.b64encode(bytes(64)).decode(), output, changes)
            self.assertEqual(ET.parse(output).find('channel/item/description').text, changes)
            self.assertNotIn('Administrator authorization', output.read_text())

    def test_package_metadata_and_invalid_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / 'Remote_Buddy_v26-10-11.021_macOS_arm64.pkg'
            package.write_bytes(b'test package bytes')
            output = Path(directory) / 'appcast.xml'
            signature = base64.b64encode(bytes(64)).decode()
            appcast.generate(package, 'v26-10-11.021', '21', signature, output)
            item = ET.parse(output).find('channel/item')
            self.assertEqual(item.find(f'{{{appcast.SPARKLE}}}version').text, '21')
            enclosure = item.find('enclosure')
            self.assertEqual(enclosure.get('length'), str(package.stat().st_size))
            self.assertEqual(item.find(f'{{{appcast.SPARKLE}}}hardwareRequirements').text, 'arm64')
            self.assertEqual(enclosure.get(f'{{{appcast.SPARKLE}}}installationType'), 'package')
            self.assertTrue(enclosure.get('url').endswith('/v26-10-11.021/' + package.name))
            for tag, version, sig in [('bad', '21', signature), ('v26-10-11.021', '0', signature),
                                      ('v26-10-11.021', '22', signature), ('v26-10-11.021', '21', 'bad'), ('v26-10-11.022', '22', signature)]:
                with self.assertRaises(ValueError):
                    appcast.generate(package, tag, version, sig, output)
            legacy_named = Path(directory) / 'Voice_Input_Buddy_v26-10-11.021_macOS_arm64.pkg'
            legacy_named.write_bytes(b'package')
            with self.assertRaises(ValueError):
                appcast.generate(legacy_named, 'v26-10-11.021', '21', signature, output)

    def test_display_suffix_wraps_without_wrapping_update_version(self):
        with tempfile.TemporaryDirectory() as directory:
            signature = base64.b64encode(bytes(64)).decode()
            for count in (999, 1000, 1001, 12345):
                tag = f'v26-10-18.{count % 1000:03d}'
                package = Path(directory) / f'Remote_Buddy_{tag}_macOS_arm64.pkg'
                package.write_bytes(b'package')
                output = Path(directory) / 'appcast.xml'
                appcast.generate(package, tag, str(count), signature, output)
                item = ET.parse(output).find('channel/item')
                self.assertEqual(item.find(f'{{{appcast.SPARKLE}}}version').text, str(count))
                self.assertEqual(item.find(f'{{{appcast.SPARKLE}}}shortVersionString').text, tag)
                with self.assertRaises(ValueError):
                    appcast.generate(package, tag, str(count + 1), signature, output)

    def test_intel_feed_and_universal_package_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            signature = base64.b64encode(bytes(64)).decode()
            package = Path(directory) / 'Remote_Buddy_v26-10-11.021_macOS_intel.pkg'
            package.write_bytes(b'package')
            output = Path(directory) / 'appcast-intel.xml'
            appcast.generate(package, 'v26-10-11.021', '21', signature, output)
            item = ET.parse(output).find('channel/item')
            self.assertIsNone(item.find(f'{{{appcast.SPARKLE}}}hardwareRequirements'))
            self.assertTrue(item.find('enclosure').get('url').endswith('_intel.pkg'))
            universal = package.with_name('Remote_Buddy_v26-10-11.021_macOS.pkg')
            universal.write_bytes(b'package')
            with self.assertRaises(ValueError):
                appcast.generate(universal, 'v26-10-11.021', '21', signature, output)

if __name__ == '__main__':
    unittest.main()
