#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/architecture.sh"
work="$root/.build/buddy-driver"
source="$work/BlackHole"
revision=e2b22aaaba4e507a097131704bf96dabc004d9cf
mkdir -p "$work" "$root/dist"
if [[ ! -d "$source/.git" ]] || ! git -C "$source" rev-parse --verify -q "$revision" >/dev/null 2>&1; then
    rm -rf "$source"
    mkdir -p "$source"
    git init --initial-branch=driver-source "$source"
    git -C "$source" remote add origin https://github.com/ExistentialAudio/BlackHole.git
    git -C "$source" fetch --depth 1 origin "$revision"
    git -C "$source" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$source" rev-parse HEAD)" == "$revision" ]] || { echo 'Unexpected BlackHole revision' >&2; exit 1; }
python3 "$root/scripts/verify-dependency-checkout.py" "$source" "$root/third_party/blackhole/device-usb.patch"
if ! git -C "$source" apply --reverse --check "$root/third_party/blackhole/device-usb.patch" 2>/dev/null; then
    if ! git -C "$source" apply --check "$root/third_party/blackhole/device-usb.patch" 2>/dev/null; then
        git -C "$source" reset --hard "$revision"
        git -C "$source" clean -fdx
    fi
    git -C "$source" apply "$root/third_party/blackhole/device-usb.patch"
fi
destination="$root/dist/RemoteBuddyMic.driver"
staging="$(mktemp -d "$root/dist/.driver-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
driver="$staging/RemoteBuddyMic.driver"
mkdir -p "$driver/Contents/MacOS" "$driver/Contents/Resources"
for arch in "$BUILD_ARCH"; do
    xcrun clang -arch "$arch" -mmacosx-version-min=14.0 -bundle -O2 -Werror=format-extra-args \
        -framework CoreFoundation -framework CoreAudio -framework Accelerate \
        '-DkDriver_Name="BuddyMic2ch"' '-DkPlugIn_BundleID="com.zfdang.remote-buddy.mic"' \
        '-DkDevice_Name="Remote Buddy Mic"' -DkNumber_Of_Channels=2 -DkHas_Driver_Name_Format=0 \
        "$source/BlackHole/BlackHole.c" -o "$staging/BuddyMic2ch-$arch"
done
cp "$staging/BuddyMic2ch-$BUILD_ARCH" "$driver/Contents/MacOS/RemoteBuddyMic"
cp "$source/BlackHole/BlackHole.plist" "$driver/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable RemoteBuddyMic' "$driver/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.zfdang.remote-buddy.mic' "$driver/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Remote Buddy Virtual Microphone' "$driver/Contents/Info.plist"
# HAL driver versions evolve independently of the dated app release.
# Installer refresh decisions compare driver content fingerprints, not these fields.
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.2' "$driver/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 3' "$driver/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile BlackHole.icns' "$driver/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSHumanReadableCopyright' "$driver/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSHumanReadableCopyright string Copyright (C) 2019 Existential Audio Inc. Modified for Remote Buddy (2026). Licensed under GPL-3.0-only.' "$driver/Contents/Info.plist"
# Check the effective identity, not only compiler command-line arguments.
strings "$driver/Contents/MacOS/RemoteBuddyMic" | grep -Fx 'BuddyMic2ch_UID' > /dev/null
if strings "$driver/Contents/MacOS/RemoteBuddyMic" | grep -F '%ich_UID' > /dev/null; then
    echo 'Driver UID still includes channel formatting' >&2
    exit 1
fi
cp "$root/Resources/AppIcon.icns" "$driver/Contents/Resources/BlackHole.icns"
cp "$source/LICENSE" "$driver/Contents/Resources/BlackHole-LICENSE"
cat > "$driver/Contents/Resources/NOTICE.txt" <<'EOF'
RemoteBuddyMic.driver
Copyright (C) 2019 Existential Audio Inc.
Modified for Remote Buddy by Remote Buddy contributors (2026).

Modification Notice (GNU General Public License v3.0, Section 5(a)):
This HAL audio driver is a modified version of Existential Audio BlackHole v0.7.1
(upstream revision e2b22aaaba4e507a097131704bf96dabc004d9cf), patched with
third_party/blackhole/device-usb.patch and compiled with Remote Buddy's bundle
identifier (com.zfdang.remote-buddy.mic), fixed UID (BuddyMic2ch_UID), and product
branding.

License: GNU General Public License v3.0 only (GPL-3.0-only).
Complete corresponding source code is published alongside releases at:
https://github.com/zfdang/remote-buddy
EOF

"$root/scripts/sign-bundle.sh" "$driver"
# Publish only after the fresh driver passes identity validation and signing.
# Failed builds leave the previous usable driver untouched.
rm -rf "$destination"
mv "$driver" "$destination"
printf 'Driver source: %s\nInclude this source and patch alongside driver releases.\n' "$source"
