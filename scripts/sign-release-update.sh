#!/bin/bash
set -euo pipefail
# Never enable shell tracing here: the private key is supplied only via stdin.
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/architecture.sh"
: "${SPARKLE_PRIVATE_KEY:?A signing key is required for production updates}"
: "${SPARKLE_PUBLIC_KEY:?Configure the public key repository variable}"
: "${RELEASE_TAG:?Release metadata is required}"
: "${RELEASE_COMMIT_COUNT:?Release metadata is required}"
: "${RELEASE_CHANGES_FILE:?Shared release changes are required}"
embedded_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$root/dist/Remote Buddy.app/Contents/Info.plist")"
[[ "$embedded_key" == "$SPARKLE_PUBLIC_KEY" ]] || { echo 'Configured and embedded public keys differ.' >&2; exit 1; }
package="$root/dist/release/Remote_Buddy_${RELEASE_TAG}_macOS_${RELEASE_ARCH_LABEL}.pkg"
signer="$root/.build/app-$BUILD_ARCH/artifacts/sparkle/Sparkle/bin/sign_update"
signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$signer" --ed-key-file - -p "$package")"
swift "$root/scripts/verify-update-signature.swift" "$embedded_key" "$signature" "$package"
python3 "$root/scripts/generate-appcast.py" --package "$package" --tag "$RELEASE_TAG" \
    --version "$RELEASE_COMMIT_COUNT" --signature "$signature" --changes-file "$RELEASE_CHANGES_FILE" --output "$root/dist/release/appcast-$RELEASE_ARCH_LABEL.xml"
echo 'Created appcast for verified combined package.'
