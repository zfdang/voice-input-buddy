#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh release view --json tagName,assets > "$work/release.json"
tag="$(python3 -c "import json; print(json.load(open('$work/release.json'))['tagName'])")"
mkdir -p "$work/candidate"
valid_candidate=false

# 1. Try explicit Actions run artifact if triggered by workflow_run
if [[ -n "${PAGES_UPDATE_RUN_ID:-}" ]]; then
    rm -rf "$work/candidate"/*
    if gh run download "$PAGES_UPDATE_RUN_ID" --name website-update-feeds --dir "$work/candidate" >/dev/null 2>&1 && \
        python3 "$root/scripts/verify-pages-update-feeds.py" "$work/candidate" "$work/release.json" >/dev/null 2>&1; then
        valid_candidate=true
    fi
fi

# 2. Try committed or pre-staged feeds in repository pages/ (e.g. from local rebuild)
if [[ "$valid_candidate" == false && -f "$root/pages/appcast-arm64.xml" && -f "$root/pages/appcast-intel.xml" ]]; then
    rm -rf "$work/candidate"/*
    cp "$root/pages/appcast-"*.xml "$work/candidate/" 2>/dev/null || true
    if python3 "$root/scripts/verify-pages-update-feeds.py" "$work/candidate" "$work/release.json" >/dev/null 2>&1; then
        valid_candidate=true
    fi
fi

# 3. Try recoverable assets attached to the latest release
if [[ "$valid_candidate" == false ]]; then
    rm -rf "$work/candidate"/*
    if gh release download "$tag" --pattern "appcast-*.xml" --dir "$work/candidate" >/dev/null 2>&1 && \
        python3 "$root/scripts/verify-pages-update-feeds.py" "$work/candidate" "$work/release.json" >/dev/null 2>&1; then
        valid_candidate=true
    fi
fi

# 4. Try recent successful release workflow runs if PAGES_UPDATE_RUN_ID was missing or expired
if [[ "$valid_candidate" == false ]]; then
    recent_runs="$(gh run list --workflow release.yml --branch main --status success --limit 3 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)"
    for candidate_run in $recent_runs; do
        if [[ "$candidate_run" != "${PAGES_UPDATE_RUN_ID:-}" ]]; then
            rm -rf "$work/candidate"/*
            if gh run download "$candidate_run" --name website-update-feeds --dir "$work/candidate" >/dev/null 2>&1 && \
                python3 "$root/scripts/verify-pages-update-feeds.py" "$work/candidate" "$work/release.json" >/dev/null 2>&1; then
                valid_candidate=true
                break
            fi
        fi
    done
fi

# 5. Try live website for website-only deploys or unchanged releases
if [[ "$valid_candidate" == false ]]; then
    rm -rf "$work/candidate"/*
    for arch in arm64 intel; do
        curl --fail --silent --show-error --retry 3 \
            "https://remote.zfdang.com/appcast-$arch.xml" -o "$work/candidate/appcast-$arch.xml"
    done
    python3 "$root/scripts/verify-pages-update-feeds.py" "$work/candidate" "$work/release.json"
    valid_candidate=true
fi

# Only publish after the complete pair passes; failure keeps the live site intact.
cp "$work/candidate/"appcast-*.xml "$root/pages/"
