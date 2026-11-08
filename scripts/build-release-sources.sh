#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/architecture.sh"
: "${RELEASE_TAG:?Run release-metadata.sh first}"
# Binaries built from local edits cannot be paired with a HEAD-only archive.
if ! git diff --quiet HEAD -- || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "Refusing to package release sources from a dirty working tree. Commit source changes first." >&2
    git status --short >&2
    exit 1
fi
work="$(mktemp -d "$root/.build/release-sources.XXXXXX")"
trap 'rm -rf "$work"' EXIT
source_root="$work/Remote_Buddy_$RELEASE_TAG"
mkdir -p "$source_root/vendor" "$root/dist/release"
# Use exactly the release commit, not unrelated local files.
git archive HEAD | tar -x -C "$source_root"
for dependency in BlackHole Sparkle; do
    if [[ "$dependency" == BlackHole ]]; then
        dependency_path="$root/.build/buddy-driver/BlackHole"
    else
        dependency_path="$root/.build/app-$BUILD_ARCH/checkouts/Sparkle"
    fi
    test -d "$dependency_path/.git"
    git -C "$dependency_path" rev-parse HEAD > "$source_root/vendor/$dependency.revision"
    mkdir -p "$source_root/vendor/$dependency"
    # Include the actual patched driver source and full dependency license files.
    tar --exclude=.git -cf - -C "$dependency_path" . | tar -xf - -C "$source_root/vendor/$dependency"
done
tar -czf "$root/dist/release/Remote_Buddy_${RELEASE_TAG}_sources.tar.gz" -C "$work" "Remote_Buddy_$RELEASE_TAG"
