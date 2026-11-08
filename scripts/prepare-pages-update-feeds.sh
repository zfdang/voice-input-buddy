#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Release jobs upload these feeds as an Actions artifact, never as Release assets.
gh release view --json tagName,assets > "$work/release.json"
mkdir -p "$work/candidate"
from_run=false
if [[ -n "${PAGES_UPDATE_RUN_ID:-}" ]]; then
    if gh run download "$PAGES_UPDATE_RUN_ID" --name website-update-feeds --dir "$work/candidate" && \
        python3 "$root/scripts/verify-pages-update-feeds.py" "$work/candidate" "$work/release.json"; then
        from_run=true
    fi
fi
if [[ "$from_run" == false ]]; then
    # Website-only deployments and immutable release reruns preserve the live
    # feeds. This also works after old Actions artifacts have expired.
    for arch in arm64 intel; do
        curl --fail --silent --show-error --retry 3 \
            "https://remote.zfdang.com/appcast-$arch.xml" -o "$work/candidate/appcast-$arch.xml"
    done
    python3 "$root/scripts/verify-pages-update-feeds.py" "$work/candidate" "$work/release.json"
fi
# Only publish after the complete pair passes; failure keeps the live site intact.
cp "$work/candidate/"appcast-*.xml "$root/pages/"
