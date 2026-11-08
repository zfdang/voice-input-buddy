#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/architecture.sh"
[[ -d "$root/dist/RemoteBuddyMic.driver" ]] || { echo 'Run scripts/build-driver.sh first' >&2; exit 1; }
test -s "$root/dist/RemoteBuddyMic.driver/Contents/MacOS/RemoteBuddyMic"
codesign --verify --deep --strict "$root/dist/RemoteBuddyMic.driver"
work="$(mktemp -d "$root/.build/driver-package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/payload/Library/Audio/Plug-Ins/HAL" "$work/scripts"
cp "$root/scripts/driver-package/"{preinstall,postinstall} "$root/scripts/installation-common.sh" "$work/scripts/"
chmod 755 "$work/scripts/"*
cp -R "$root/dist/RemoteBuddyMic.driver" "$work/payload/Library/Audio/Plug-Ins/HAL/"
pkgbuild --root "$work/payload" --identifier com.zfdang.remote-buddy.mic.installer \
    --version 0.1.2 --scripts "$work/scripts" --install-location / "$work/component.pkg"
"$root/scripts/build-installer-product.sh" "$work/component.pkg" "$root/dist/RemoteBuddy-Microphone.pkg"
echo 'Built unsigned, unnotarized installer with a pre-install audio interruption notice.'
