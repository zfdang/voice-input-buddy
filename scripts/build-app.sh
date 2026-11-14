#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# Local and CI builds derive display and bundle versions from the same Git metadata.
release_metadata="$(scripts/release-metadata.sh)"
while IFS='=' read -r key value; do
    case "$key" in
        RELEASE_TAG|RELEASE_BUNDLE_VERSION|RELEASE_COMMIT_COUNT|RELEASE_PACKAGE_VERSION)
            export "$key=$value" ;;
    esac
done <<< "$release_metadata"
: "${RELEASE_TAG:?Release metadata is required}"
configuration="${CONFIGURATION:-release}"
source scripts/architecture.sh
scratch="${APP_BUILD_SCRATCH_PATH:-$root/.build/app-$BUILD_ARCH}"
verify_sparkle_checkout() {
    if [[ ! -d "$scratch/checkouts/Sparkle/.git" ]]; then
        return 0
    fi
    local sparkle_revision
    sparkle_revision="$(python3 -c '
import json
with open("Package.resolved") as f:
    pins = json.load(f)["pins"]
print(next(p["state"]["revision"] for p in pins if p["identity"].lower() == "sparkle"))
')"
    python3 scripts/verify-dependency-checkout.py "$scratch/checkouts/Sparkle" --expected-revision "$sparkle_revision"
}
verify_sparkle_checkout
swift build --disable-keychain --scratch-path "$scratch" -c "$configuration" --arch "$BUILD_ARCH" --product RemoteBuddy
verify_sparkle_checkout
bin="$(swift build --disable-keychain --scratch-path "$scratch" -c "$configuration" --arch "$BUILD_ARCH" --show-bin-path)"
destination="$root/dist/Remote Buddy.app"
mkdir -p "$root/dist"
staging="$(mktemp -d "$root/dist/.app-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Remote Buddy.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/RemoteBuddy" "$app/Contents/MacOS/RemoteBuddy"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/. "$app/Contents/Resources/"
# Build source artwork is not a runtime resource; retain the compiled AppIcon.icns.
rm -rf "$app/Contents/Resources/AppIcon.iconset" "$app/Contents/Resources/AppIcon.png" \
    "$app/Contents/Resources/RemoteIllustrations" "$app/Contents/Resources/IconArtwork"
python3 scripts/generate-common-phrases.py Resources/CommonPhrases/built-in.md "$app/Contents/Resources/CommonPhrases.json"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp -R "$bin/Sparkle.framework" "$app/Contents/Frameworks/"
python3 scripts/thin-framework.py "$app/Contents/Frameworks/Sparkle.framework" "$BUILD_ARCH"
if ! otool -l "$app/Contents/MacOS/RemoteBuddy" | sed -n '/cmd LC_RPATH/,+3p' | grep -Fq '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/RemoteBuddy"
fi
if [[ -n "${RELEASE_BUNDLE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_BUNDLE_VERSION" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_COMMIT_COUNT" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :BuddyReleaseVersion string $RELEASE_TAG" "$app/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :SUFeedURL https://remote.zfdang.com/appcast-$RELEASE_ARCH_LABEL.xml" "$app/Contents/Info.plist"
python3 scripts/verify-onboarding-resources.py "$app/Contents/Resources"
"$root/scripts/sign-bundle.sh" "$app"
# Publish only after the fresh bundle passes resource validation and signing.
# Failed builds leave the previous usable app untouched.
rm -rf "$destination"
mv "$app" "$destination"
printf 'Built %s\n' "$destination"
