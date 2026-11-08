#!/usr/bin/env python3
import base64
import json
import os
import shutil
import subprocess
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

feeds = module('feeds', 'verify-pages-update-feeds.py')
appcast = module('appcast', 'generate-appcast.py')

class FeedDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tag = 'v26-10-12.043'
        self.release = {'tagName': self.tag, 'assets': []}
        for arch in ['arm64', 'intel']:
            package = self.root / f'Remote_Buddy_{self.tag}_macOS_{arch}.pkg'
            package.write_bytes(b'package')
            self.release['assets'].append({'name': package.name})
            appcast.generate(package, self.tag, '43', base64.b64encode(bytes(64)).decode(), self.root / f'appcast-{arch}.xml')

    def test_complete_pair_matches_published_packages(self):
        feeds.verify(self.root, self.release)

    def test_build_version_can_exceed_tag_suffix(self):
        for arch in ['arm64', 'intel']:
            path = self.root / f'appcast-{arch}.xml'
            xml = ET.parse(path)
            xml.find(f'channel/item/{{{appcast.SPARKLE}}}version').text = '1043'
            xml.write(path)
        feeds.verify(self.root, self.release)

    def test_stale_feed_cannot_replace_the_live_pair(self):
        self.release['tagName'] = 'v26-10-12.044'
        with self.assertRaises(ValueError): feeds.verify(self.root, self.release)

    def test_unknown_or_unsigned_package_is_rejected(self):
        path = self.root / 'appcast-intel.xml'
        xml = ET.parse(path); enclosure = xml.find('channel/item/enclosure')
        enclosure.set('url', 'https://example.invalid/package.pkg'); xml.write(path)
        with self.assertRaises(ValueError): feeds.verify(self.root, self.release)
        enclosure.set('url', f'https://github.com/zfdang/remote-buddy/releases/download/{self.tag}/Remote_Buddy_{self.tag}_macOS_intel.pkg')
        enclosure.set(f'{{{appcast.SPARKLE}}}edSignature', ''); xml.write(path)
        with self.assertRaises(ValueError): feeds.verify(self.root, self.release)

    def test_missing_architecture_or_asset_is_rejected(self):
        self.release['assets'].pop()
        with self.assertRaises(ValueError): feeds.verify(self.root, self.release)
        (self.root / 'appcast-intel.xml').unlink()
        with self.assertRaises(FileNotFoundError): feeds.verify(self.root, self.release)

    def deploy(self, artifact, valid=True):
        project = self.root / 'project'
        scripts = project / 'scripts'; scripts.mkdir(parents=True)
        (project / 'pages').mkdir()
        for name in ['prepare-pages-update-feeds.sh', 'verify-pages-update-feeds.py']:
            shutil.copy2(Path(__file__).with_name(name), scripts / name)
        artifact_directory = self.root / 'artifact'; artifact_directory.mkdir()
        for path in self.root.glob('appcast-*.xml'):
            shutil.copy2(path, artifact_directory / path.name)
        if not valid:
            path = artifact_directory / 'appcast-arm64.xml'
            path.write_text(path.read_text().replace(self.tag, 'v26-10-12.042'))
        release = self.root / 'release.json'; release.write_text(json.dumps(self.release))
        binaries = self.root / 'bin'; binaries.mkdir()
        gh = binaries / 'gh'
        gh.write_text("""#!/usr/bin/env python3
import os, pathlib, shutil, sys
args=sys.argv[1:]
if args[:2]==['release','view']:
    print(pathlib.Path(os.environ['FIXTURE_RELEASE']).read_text())
elif args[:2]==['run','download'] and os.environ['FIXTURE_ARTIFACT']=='1':
    destination=pathlib.Path(args[args.index('--dir')+1]); destination.mkdir(exist_ok=True)
    for source in pathlib.Path(os.environ['FIXTURE_ARTIFACT_DIR']).glob('appcast-*.xml'):
        shutil.copy2(source,destination/source.name)
else:
    sys.exit(1)
""")
        curl = binaries / 'curl'
        curl.write_text("""#!/usr/bin/env python3
import os, pathlib, shutil, sys
args=sys.argv[1:]
url=next(arg for arg in args if arg.startswith('https://'))
filename=url.rsplit('/',1)[1]
shutil.copy2(pathlib.Path(os.environ['FIXTURE_LIVE'])/filename,args[args.index('-o')+1])
""")
        gh.chmod(0o755); curl.chmod(0o755)
        environment = {**os.environ, 'PATH': str(binaries) + os.pathsep + os.environ['PATH'],
                       'PAGES_UPDATE_RUN_ID': '123' if artifact else '',
                       'FIXTURE_RELEASE': str(release), 'FIXTURE_ARTIFACT': '1' if artifact else '0',
                       'FIXTURE_ARTIFACT_DIR': str(artifact_directory), 'FIXTURE_LIVE': str(self.root)}
        subprocess.run(['bash', str(scripts / 'prepare-pages-update-feeds.sh')], env=environment,
                       capture_output=True, check=True)
        feeds.verify(project / 'pages', self.release)

    def test_release_workflow_downloads_metadata_artifact(self):
        self.deploy(artifact=True)

    def test_website_only_deploy_preserves_live_feeds(self):
        self.deploy(artifact=False)

    def test_stale_run_artifact_falls_back_to_current_live_feeds(self):
        self.deploy(artifact=True, valid=False)

if __name__ == '__main__': unittest.main()
