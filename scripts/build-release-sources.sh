#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/architecture.sh"
: "${RELEASE_TAG:?Run release-metadata.sh first}"
expected_release_tag="$("$root/scripts/release-metadata.sh" | sed -n 's/^RELEASE_TAG=//p')"
if [[ "$RELEASE_TAG" != "$expected_release_tag" ]]; then
    echo "RELEASE_TAG ($RELEASE_TAG) does not match HEAD release metadata ($expected_release_tag)." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$RELEASE_TAG" >/dev/null && \
   [[ "$(git rev-parse "refs/tags/$RELEASE_TAG^{}")" != "$(git rev-parse HEAD)" ]]; then
    echo "Existing tag $RELEASE_TAG does not point to HEAD." >&2
    exit 1
fi
# Binaries built from local edits cannot be paired with a HEAD-only archive.
if ! git diff --quiet HEAD -- || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "Refusing to package release sources from a dirty working tree. Commit source changes first." >&2
    git status --short >&2
    exit 1
fi
sparkle_revision="$(python3 -c '
import json
with open("Package.resolved") as f:
    pins = json.load(f)["pins"]
print(next(p["state"]["revision"] for p in pins if p["identity"].lower() == "sparkle"))
')"
blackhole_revision="$(sed -n 's/^revision=//p' "$root/scripts/build-driver.sh")"
work="$(mktemp -d "$root/.build/release-sources.XXXXXX")"
trap 'rm -rf "$work"' EXIT
source_root="$work/Remote_Buddy_$RELEASE_TAG"
mkdir -p "$source_root/vendor" "$root/dist/release"
# Use exactly the release commit, not unrelated local files.
git archive HEAD | tar -x -C "$source_root"
for dependency in BlackHole Sparkle; do
    if [[ "$dependency" == BlackHole ]]; then
        dependency_path="$root/.build/buddy-driver/BlackHole"
        python3 "$root/scripts/verify-dependency-checkout.py" "$dependency_path" "$root/third_party/blackhole/device-usb.patch" --expected-revision "$blackhole_revision"
    else
        dependency_path="$root/.build/app-$BUILD_ARCH/checkouts/Sparkle"
        python3 "$root/scripts/verify-dependency-checkout.py" "$dependency_path" --expected-revision "$sparkle_revision"
    fi
    test -d "$dependency_path/.git"
    git -C "$dependency_path" rev-parse HEAD > "$source_root/vendor/$dependency.revision"
    mkdir -p "$source_root/vendor/$dependency"
    # Include the actual patched driver source and full dependency license files.
    tar --exclude=.git --exclude=__pycache__ --exclude='*.pyc' -cf - -C "$dependency_path" . | tar -xf - -C "$source_root/vendor/$dependency"
done
tar -czf "$root/dist/release/Remote_Buddy_${RELEASE_TAG}_sources.tar.gz" -C "$work" "Remote_Buddy_$RELEASE_TAG"
