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

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PUBLIC_KEY = "8aHZRXuY+Q0F0FsWNyQTx0wIYXi4MoCCSzAWs0j+uR4="


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


appcast_module = load_module("generate_appcast", "generate-appcast.py")
verify_module = load_module("verify_pages_update_feeds", "verify-pages-update-feeds.py")


def sign_payload(package_path, private_key_b64):
    """Sign package payload with Ed25519 private key."""
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        priv = Ed25519PrivateKey.from_private_bytes(base64.b64decode(private_key_b64))
        sig = priv.sign(package_path.read_bytes())
        return base64.b64encode(sig).decode()
    except ImportError:
        pass

    # Fallback to Swift with CryptoKit
    swift_script = """
import Foundation
import CryptoKit

guard CommandLine.arguments.count == 3,
      let keyData = Data(base64Encoded: CommandLine.arguments[1]) else {
    exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let signature = try key.signature(for: payload)
print(signature.base64EncodedString())
"""
    result = subprocess.run(
        ["swift", "-e", swift_script, private_key_b64, str(package_path)],
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

    public_key = public_key or os.environ.get("SPARKLE_PUBLIC_KEY") or DEFAULT_PUBLIC_KEY
    private_key = private_key or os.environ.get("SPARKLE_PRIVATE_KEY")

    if version is None:
        raw_version = tag.rsplit(".", 1)[1].lstrip("0")
        version = raw_version if raw_version else "1"
        # If git history is available, prefer rev-list count matching modulo 1000
        try:
            res = subprocess.run(
                ["git", "rev-list", "--count", "HEAD"],
                capture_output=True,
                text=True
            )
            if res.returncode == 0 and res.stdout.strip().isdigit():
                git_count = res.stdout.strip()
                if int(git_count) % 1000 == int(tag.rsplit(".", 1)[1]):
                    version = git_count
        except Exception:
            pass

    if changes is None:
        changes = release_metadata.get("body", "").strip() or "此版本未提供更新摘要。"

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

    try:
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
            else:
                pkg_path = Path(pkg_path)

            sig = signatures[arch]
            if not sig:
                if private_key:
                    sig = sign_payload(pkg_path, private_key)
                else:
                    raise ValueError(f"Missing signature for {arch} package {pkg_name}")

            verify_payload_signature(pkg_path, sig, public_key)

            dest_appcast = output_path / f"appcast-{arch}.xml"
            appcast_module.generate(
                package=pkg_path,
                tag=tag,
                version=version,
                signature=sig,
                output=dest_appcast,
                changes=changes,
            )

        verify_module.verify(output_path, release_metadata)
        print(f"Successfully rebuilt and verified update feeds in {output_path} for release {tag}")
    finally:
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
    parser.add_argument("--private-key", help="Sparkle private key for signing")
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

    changes = args.changes_file.read_text() if args.changes_file else None
    release_metadata = json.loads(Path(args.release_json).read_text()) if args.release_json else None

    rebuild(
        tag=args.tag,
        release_metadata=release_metadata,
        arm64_package=args.arm64_package,
        intel_package=args.intel_package,
        arm64_signature=arm64_sig,
        intel_signature=intel_sig,
        private_key=args.private_key,
        public_key=args.public_key,
        version=args.version,
        changes=changes,
        output_dir=args.output_dir,
        download_dir=args.download_dir,
    )


if __name__ == "__main__":
    main()
