#!/usr/bin/env python3
"""Reliably rebuild update feeds from published packages and signatures."""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PUBLIC_KEY = "8aHZRXuY+Q0F0FsWNyQTx0wIYXi4MoCCSzAWs0j+uR4="


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


appcast_module = load_module("generate_appcast", "generate-appcast.py")
verify_module = load_module("verify_pages_update_feeds", "verify-pages-update-feeds.py")


def get_embedded_public_key():
    import plistlib
    for plist_path in [
        ROOT / "Resources" / "Info.plist",
        ROOT / "dist" / "Remote Buddy.app" / "Contents" / "Info.plist",
    ]:
        if plist_path.exists():
            try:
                with open(plist_path, "rb") as f:
                    plist = plistlib.load(f)
            except Exception as exc:
                raise ValueError(f"Failed to parse {plist_path}: {exc}") from exc
            if "SUPublicEDKey" in plist:
                return plist["SUPublicEDKey"]
    return DEFAULT_PUBLIC_KEY


def sign_payload(package_path, private_key_b64):
    """Sign package payload with Ed25519 private key. Private key is never passed via argv.
    Supports both 32-byte seeds and 64-byte private keys.
    """
    key_bytes = base64.b64decode(private_key_b64)
    if len(key_bytes) == 64:
        key_bytes = key_bytes[:32]
    raw_key_b64 = base64.b64encode(key_bytes).decode()

    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        priv = Ed25519PrivateKey.from_private_bytes(key_bytes)
        sig = priv.sign(package_path.read_bytes())
        return base64.b64encode(sig).decode()
    except ImportError:
        pass

    # Fallback to Swift with CryptoKit, reading private key strictly via stdin
    swift_script = """
import Foundation
import CryptoKit

guard CommandLine.arguments.count == 2 else { exit(1) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let keyString = String(data: input, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let keyData = Data(base64Encoded: keyString) else {
    exit(1)
}
let seed = keyData.count == 64 ? keyData.prefix(32) : keyData
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let signature = try key.signature(for: payload)
print(signature.base64EncodedString())
"""
    result = subprocess.run(
        ["swift", "-e", swift_script, str(package_path)],
        input=raw_key_b64,
        capture_output=True,
        text=True,
        check=True
    )
    return result.stdout.strip()


def verify_payload_signature(package_path, signature_b64, public_key_b64):
    """Verify package Ed25519 signature against public key."""
    if len(base64.b64decode(signature_b64, validate=True)) != 64:
        raise ValueError("Invalid signature length")

    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64))
        pub.verify(base64.b64decode(signature_b64), package_path.read_bytes())
        return True
    except ImportError:
        pass

    verify_script = Path(__file__).with_name("verify-update-signature.swift")
    result = subprocess.run(
        ["swift", str(verify_script), public_key_b64, signature_b64, str(package_path)],
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        raise ValueError(f"Signature verification failed: {result.stderr.strip()}")
    return True


def extract_summary_from_release_body(body):
    """Extract clean update summary from release notes markdown body."""
    if not body:
        return "此版本未提供更新摘要。"
    lines = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("[查看完整变化](") or line.startswith("首次发布"):
            continue
        line = re.sub(r'\(\[([0-9a-f]{7,})\]\([^\)]+\)\)', r'(\1)', line)
        line = re.sub(r'\\([\\`*_\[\]<>])', r'\1', line)
        lines.append(line)
    return "\n".join(lines).strip() or "此版本未提供更新摘要。"


def extract_version_from_pkg(pkg_path):
    """Try to extract CFBundleVersion directly from a .pkg installer bundle."""
    if not pkg_path or not Path(pkg_path).exists():
        return None
    try:
        with tempfile.TemporaryDirectory() as td:
            expanded = Path(td) / "expanded"
            res = subprocess.run(
                ["pkgutil", "--expand-full", str(pkg_path), str(expanded)],
                capture_output=True,
                text=True
            )
            if res.returncode == 0:
                import plistlib
                candidates = list(expanded.glob("**/Applications/*.app/Contents/Info.plist"))
                if not candidates:
                    candidates = list(expanded.glob("**/Contents/Info.plist"))
                for candidate in candidates:
                    try:
                        with open(candidate, "rb") as f:
                            plist = plistlib.load(f)
                            pkg_type = plist.get("CFBundlePackageType")
                            bundle_id = plist.get("CFBundleIdentifier", "")
                            if pkg_type == "APPL" or bundle_id == "com.zfdang.remote-buddy":
                                cf_ver = plist.get("CFBundleVersion")
                                if cf_ver and str(cf_ver).isdigit():
                                    return str(cf_ver)
                    except Exception:
                        continue
    except Exception:
        pass
    return None


def resolve_version(tag, explicit_version=None, target_commitish=None, existing_feed_path=None, pkg_path=None):
    """Resolve build version integer matching commit count, avoiding 1000-modulo rollback."""
    if explicit_version:
        return str(explicit_version)

    tag_mod = int(tag.rsplit(".", 1)[1])

    # 1. Inspect package if available
    pkg_ver = extract_version_from_pkg(pkg_path)
    if pkg_ver and int(pkg_ver) % 1000 == tag_mod:
        return str(pkg_ver)

    # 2. Inspect git history if available
    for ref in [tag, target_commitish]:
        if not ref:
            continue
        try:
            res = subprocess.run(
                ["git", "rev-list", "--count", ref],
                capture_output=True,
                text=True
            )
            if res.returncode == 0 and res.stdout.strip().isdigit():
                count = int(res.stdout.strip())
                if count % 1000 == tag_mod:
                    return str(count)
        except Exception:
            pass

    # 3. Check existing feed for base thousands
    if existing_feed_path and Path(existing_feed_path).exists():
        try:
            tree = ET.parse(existing_feed_path)
            ver = tree.findtext(f'.//{{{appcast_module.SPARKLE}}}version')
            if ver and ver.isdigit():
                prev_count = int(ver)
                prev_tag = tree.findtext('.//channel/item/title')
                if prev_tag == tag:
                    return str(prev_count)
                base = (prev_count // 1000) * 1000
                if prev_count % 1000 >= tag_mod:
                    base += 1000
                return str(base + tag_mod)
        except Exception:
            pass

    raise ValueError(
        f"Cannot reliably determine full build version for release {tag}. "
        "Please specify --version explicitly."
    )


def fetch_release_metadata(tag=None, release_json=None):
    if release_json and Path(release_json).exists():
        return json.loads(Path(release_json).read_text())
    cmd = ["gh", "release", "view"]
    if tag:
        cmd.append(tag)
    cmd.extend(["--json", "tagName,assets,body,targetCommitish"])
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(res.stdout)


def rebuild(
    tag=None,
    release_metadata=None,
    arm64_package=None,
    intel_package=None,
    arm64_signature=None,
    intel_signature=None,
    private_key=None,
    public_key=None,
    version=None,
    changes=None,
    output_dir=None,
    download_dir=None,
):
    if release_metadata is None:
        release_metadata = fetch_release_metadata(tag)

    tag = release_metadata["tagName"]
    if not re.fullmatch(r"v\d{2}-\d{2}-\d{2}\.\d{3}", tag):
        raise ValueError(f"Invalid release tag: {tag}")

    embedded_public_key = get_embedded_public_key()
    public_key = public_key or os.environ.get("SPARKLE_PUBLIC_KEY") or embedded_public_key
    if embedded_public_key and public_key != embedded_public_key:
        raise ValueError(f"Public key ({public_key}) differs from Info.plist SUPublicEDKey ({embedded_public_key})")

    private_key = private_key or os.environ.get("SPARKLE_PRIVATE_KEY")

    output_path = Path(output_dir or (ROOT / "pages"))
    output_path.mkdir(parents=True, exist_ok=True)

    packages = {"arm64": arm64_package, "intel": intel_package}
    signatures = {"arm64": arm64_signature, "intel": intel_signature}

    temp_dir = None
    if download_dir is None:
        temp_dir = tempfile.TemporaryDirectory()
        download_dir = Path(temp_dir.name)
    else:
        download_dir = Path(download_dir)
        download_dir.mkdir(parents=True, exist_ok=True)

    # Use a staging directory for atomic publication
    staging_dir = tempfile.TemporaryDirectory(dir=output_path)
    staging_path = Path(staging_dir.name)

    try:
        # Resolve package paths first (downloading if necessary)
        for arch in ["arm64", "intel"]:
            pkg_name = f"Remote_Buddy_{tag}_macOS_{arch}.pkg"
            pkg_path = packages[arch]
            if pkg_path is None or not Path(pkg_path).exists():
                local_candidate = download_dir / pkg_name
                if not local_candidate.exists():
                    subprocess.run(
                        ["gh", "release", "download", tag, "-p", pkg_name, "--dir", str(download_dir)],
                        check=True
                    )
                pkg_path = local_candidate
            packages[arch] = Path(pkg_path)

        if version is None:
            existing_feed = output_path / "appcast-arm64.xml"
            version = resolve_version(
                tag,
                explicit_version=None,
                target_commitish=release_metadata.get("targetCommitish"),
                existing_feed_path=existing_feed,
                pkg_path=packages["arm64"]
            )

        if changes is None:
            changes = extract_summary_from_release_body(release_metadata.get("body", ""))

        for arch in ["arm64", "intel"]:
            pkg_path = packages[arch]
            sig = signatures[arch]
            if not sig:
                if private_key:
                    sig = sign_payload(pkg_path, private_key)
                else:
                    raise ValueError(f"Missing signature for {arch} package {pkg_path.name}")

            verify_payload_signature(pkg_path, sig, public_key)

            dest_appcast = staging_path / f"appcast-{arch}.xml"
            appcast_module.generate(
                package=pkg_path,
                tag=tag,
                version=version,
                signature=sig,
                output=dest_appcast,
                changes=changes,
            )

        # Verify candidate feeds before publishing
        verify_module.verify(staging_path, release_metadata)

        # Atomically replace files in output_path
        for arch in ["arm64", "intel"]:
            src = staging_path / f"appcast-{arch}.xml"
            dst = output_path / f"appcast-{arch}.xml"
            os.replace(src, dst)

        print(f"Successfully rebuilt and verified update feeds in {output_path} for release {tag}")
    finally:
        staging_dir.cleanup()
        if temp_dir:
            temp_dir.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Release tag (e.g. v26-11-08.579)")
    parser.add_argument("--release-json", help="Path to cached release JSON")
    parser.add_argument("--arm64-package", type=Path, help="Path to arm64 pkg")
    parser.add_argument("--intel-package", type=Path, help="Path to intel pkg")
    parser.add_argument("--arm64-signature", help="Base64 Ed25519 signature for arm64 pkg")
    parser.add_argument("--intel-signature", help="Base64 Ed25519 signature for intel pkg")
    parser.add_argument("--signatures-file", type=Path, help="JSON file with arm64 and intel signatures")
    parser.add_argument("--private-key-file", type=Path, help="Path to file containing private key, or '-' for stdin")
    parser.add_argument("--public-key", help="Sparkle public key for verification")
    parser.add_argument("--version", help="Bundle version number")
    parser.add_argument("--changes-file", type=Path, help="File containing changelog")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "pages", help="Output directory")
    parser.add_argument("--download-dir", type=Path, help="Directory to store downloaded packages")

    args = parser.parse_args()

    arm64_sig = args.arm64_signature
    intel_sig = args.intel_signature
    if args.signatures_file and args.signatures_file.exists():
        sigs = json.loads(args.signatures_file.read_text())
        arm64_sig = arm64_sig or sigs.get("arm64")
        intel_sig = intel_sig or sigs.get("intel")

    private_key = None
    if args.private_key_file:
        if str(args.private_key_file) == "-":
            private_key = sys.stdin.read().strip()
        else:
            private_key = args.private_key_file.read_text().strip()

    changes = args.changes_file.read_text() if args.changes_file else None
    release_metadata = json.loads(Path(args.release_json).read_text()) if args.release_json else None

    rebuild(
        tag=args.tag,
        release_metadata=release_metadata,
        arm64_package=args.arm64_package,
        intel_package=args.intel_package,
        arm64_signature=arm64_sig,
        intel_signature=intel_sig,
        private_key=private_key,
        public_key=args.public_key,
        version=args.version,
        changes=changes,
        output_dir=args.output_dir,
        download_dir=args.download_dir,
    )


if __name__ == "__main__":
    main()
