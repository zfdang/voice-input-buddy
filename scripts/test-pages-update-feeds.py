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
rebuild = module('rebuild', 'rebuild-pages-update-feeds.py')

def generate_disposable_keypair():
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        priv = Ed25519PrivateKey.generate()
        priv_b64 = base64.b64encode(priv.private_bytes_raw()).decode()
        pub = priv.public_key()
        pub_b64 = base64.b64encode(pub.public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
        return priv_b64, pub_b64
    except ImportError:
        script = """import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
"""
        res = subprocess.run(["swift", "-e", script], capture_output=True, text=True, check=True)
        priv_b64, pub_b64 = res.stdout.strip().splitlines()
        return priv_b64, pub_b64


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

    def test_previous_repository_url_is_accepted_for_existing_release(self):
        for path in self.root.glob('appcast-*.xml'):
            tree = ET.parse(path)
            enclosure = tree.find('channel/item/enclosure')
            enclosure.set('url', enclosure.get('url').replace('/remote-buddy/', '/voice-input-buddy/'))
            tree.write(path)
        feeds.verify(self.root, self.release)

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

    def deploy(self, artifact, valid=True, live_valid=True, release_assets=False, prebuilt_pages=False, recent_run=False):
        project = self.root / 'project'
        scripts = project / 'scripts'; scripts.mkdir(parents=True, exist_ok=True)
        pages_dir = project / 'pages'; pages_dir.mkdir(parents=True, exist_ok=True)
        for name in ['prepare-pages-update-feeds.sh', 'verify-pages-update-feeds.py']:
            shutil.copy2(Path(__file__).with_name(name), scripts / name)
        artifact_directory = self.root / 'artifact'; artifact_directory.mkdir(parents=True, exist_ok=True)
        for path in self.root.glob('appcast-*.xml'):
            shutil.copy2(path, artifact_directory / path.name)
        if not valid:
            path = artifact_directory / 'appcast-arm64.xml'
            path.write_text(path.read_text().replace(self.tag, 'v26-10-12.042'))
        live_directory = self.root / 'live'; live_directory.mkdir(parents=True, exist_ok=True)
        for path in self.root.glob('appcast-*.xml'):
            shutil.copy2(path, live_directory / path.name)
        if not live_valid:
            path = live_directory / 'appcast-arm64.xml'
            path.write_text(path.read_text().replace(self.tag, 'v26-10-12.042'))
        if prebuilt_pages:
            for path in self.root.glob('appcast-*.xml'):
                shutil.copy2(path, pages_dir / path.name)
        release = self.root / 'release.json'; release.write_text(json.dumps(self.release))
        binaries = self.root / 'bin'; binaries.mkdir(parents=True, exist_ok=True)
        gh = binaries / 'gh'
        gh.write_text("""#!/usr/bin/env python3
import os, pathlib, shutil, sys
args=sys.argv[1:]
if args[:2]==['release','view']:
    print(pathlib.Path(os.environ['FIXTURE_RELEASE']).read_text())
elif args[:2]==['run','download']:
    if os.environ.get('FIXTURE_ARTIFACT')=='1' or os.environ.get('FIXTURE_RECENT_RUN')=='1':
        destination=pathlib.Path(args[args.index('--dir')+1]); destination.mkdir(exist_ok=True)
        for source in pathlib.Path(os.environ['FIXTURE_ARTIFACT_DIR']).glob('appcast-*.xml'):
            shutil.copy2(source,destination/source.name)
    else:
        sys.exit(1)
elif args[:2]==['release','download'] and os.environ.get('FIXTURE_RELEASE_ASSETS')=='1':
    destination=pathlib.Path(args[args.index('--dir')+1]); destination.mkdir(exist_ok=True)
    for source in pathlib.Path(os.environ['FIXTURE_ARTIFACT_DIR']).glob('appcast-*.xml'):
        shutil.copy2(source,destination/source.name)
elif args[:2]==['run','list']:
    if os.environ.get('FIXTURE_RECENT_RUN')=='1':
        print("99999")
    else:
        print("")
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
                       'FIXTURE_RECENT_RUN': '1' if recent_run else '0',
                       'FIXTURE_RELEASE_ASSETS': '1' if release_assets else '0',
                       'FIXTURE_ARTIFACT_DIR': str(artifact_directory), 'FIXTURE_LIVE': str(live_directory)}
        subprocess.run(['bash', str(scripts / 'prepare-pages-update-feeds.sh')], env=environment,
                       capture_output=True, check=True)
        feeds.verify(project / 'pages', self.release)

    def test_release_workflow_downloads_metadata_artifact(self):
        self.deploy(artifact=True)

    def test_website_only_deploy_preserves_live_feeds(self):
        self.deploy(artifact=False)

    def test_stale_run_artifact_falls_back_to_current_live_feeds(self):
        self.deploy(artifact=True, valid=False)

    def test_stale_live_recovers_from_release_assets_when_artifact_missing(self):
        self.deploy(artifact=False, live_valid=False, release_assets=True)

    def test_stale_live_recovers_from_prebuilt_pages_feeds_when_artifact_missing(self):
        self.deploy(artifact=False, live_valid=False, prebuilt_pages=True)

    def test_stale_live_recovers_from_recent_workflow_runs_when_artifact_missing(self):
        self.deploy(artifact=False, live_valid=False, recent_run=True)

    def test_extract_summary_from_release_body(self):
        body = """
- [新增] 添加新功能 ([1234567](https://github.com/zfdang/remote-buddy/commit/1234567))
- [修复] 修复错误 ([abcdef0](https://github.com/zfdang/remote-buddy/commit/abcdef0))

[查看完整变化](https://github.com/zfdang/remote-buddy/compare/v26-10-11.042...v26-10-12.043)
"""
        summary = rebuild.extract_summary_from_release_body(body)
        self.assertIn("- [新增] 添加新功能 (1234567)", summary)
        self.assertIn("- [修复] 修复错误 (abcdef0)", summary)
        self.assertNotIn("查看完整变化", summary)
        self.assertNotIn("https://github.com", summary)

    def test_rebuild_pages_update_feeds_with_real_ed25519_signatures(self):
        priv_b64, pub_b64 = generate_disposable_keypair()

        pkgs = {}
        sigs = {}
        for arch in ['arm64', 'intel']:
            pkg = self.root / f'Remote_Buddy_{self.tag}_macOS_{arch}.pkg'
            pkg.write_bytes(f'pkg-payload-{arch}'.encode())
            pkgs[arch] = pkg
            sigs[arch] = rebuild.sign_payload(pkg, priv_b64)

        # Verify real signatures work
        for arch in ['arm64', 'intel']:
            self.assertTrue(rebuild.verify_payload_signature(pkgs[arch], sigs[arch], pub_b64))

        # Corrupted signature is rejected
        bad_sig = base64.b64encode(bytes(64)).decode()
        with self.assertRaises(Exception):
            rebuild.verify_payload_signature(pkgs['arm64'], bad_sig, pub_b64)

        out = self.root / 'rebuilt_pages'
        orig_embedded = rebuild.get_embedded_public_key
        try:
            rebuild.get_embedded_public_key = lambda: pub_b64
            rebuild.rebuild(
                tag=self.tag,
                release_metadata=self.release,
                arm64_package=pkgs['arm64'],
                intel_package=pkgs['intel'],
                arm64_signature=sigs['arm64'],
                intel_signature=sigs['intel'],
                public_key=pub_b64,
                version='43',
                output_dir=out
            )
            feeds.verify(out, self.release)
        finally:
            rebuild.get_embedded_public_key = orig_embedded

    def test_rebuild_rejects_mismatched_public_key(self):
        orig_embedded = rebuild.get_embedded_public_key
        try:
            rebuild.get_embedded_public_key = lambda: "embedded_key_different"
            with self.assertRaises(ValueError) as ctx:
                rebuild.rebuild(
                    tag=self.tag,
                    release_metadata=self.release,
                    public_key="some_other_key",
                )
            self.assertIn("differs from Info.plist", str(ctx.exception))
        finally:
            rebuild.get_embedded_public_key = orig_embedded

    def test_version_resolution_across_thousand_commit_boundary(self):
        existing_feed = self.root / 'appcast-arm64.xml'
        # With real git tag v26-10-12.043, git rev-list returns 43
        ver = rebuild.resolve_version('v26-10-12.043', existing_feed_path=existing_feed)
        self.assertEqual(ver, '43')

        # For a tag not in git history (or shallow checkout), existing feed base is used:
        # When existing feed has build 1042, next tag ending in 043 resolves to 1043
        xml = ET.parse(existing_feed)
        xml.find(f'channel/item/{{{appcast.SPARKLE}}}version').text = '1042'
        xml.write(existing_feed)

        ver = rebuild.resolve_version('v99-10-12.043', existing_feed_path=existing_feed)
        self.assertEqual(ver, '1043')

        # Test wraparound from 1042 to 000 -> 2000
        ver_wrap = rebuild.resolve_version('v99-10-12.000', existing_feed_path=existing_feed)
        self.assertEqual(ver_wrap, '2000')

        # Without git history and without existing feed, it raises ValueError instead of guessing
        with self.assertRaises(ValueError) as ctx:
            rebuild.resolve_version('v99-10-12.043', existing_feed_path=self.root / 'nonexistent.xml')
        self.assertIn("Cannot reliably determine", str(ctx.exception))

if __name__ == '__main__': unittest.main()
