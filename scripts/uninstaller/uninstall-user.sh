#!/bin/bash
set -euo pipefail
# Personal data is removed as the invoking user, never as root.
[[ "$(/usr/bin/id -u)" != 0 ]] || { echo 'Run the uninstaller from your own account.' >&2; exit 1; }
case "${1:-}" in
prepare)
    /usr/bin/pkill -u "$(/usr/bin/id -u)" -x VoiceInputBuddy || true
    for attempt in {1..50}; do
        /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x VoiceInputBuddy >/dev/null || break
        /bin/sleep 0.1
    done
    if /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x VoiceInputBuddy >/dev/null; then
        /usr/bin/pkill -9 -u "$(/usr/bin/id -u)" -x VoiceInputBuddy || true
        for attempt in {1..20}; do
            /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x VoiceInputBuddy >/dev/null || break
            /bin/sleep 0.1
        done
    fi
    if /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x VoiceInputBuddy >/dev/null; then
        echo 'Quit Voice Input Buddy before uninstalling.' >&2; exit 1
    fi
    app='/Applications/Voice Input Buddy.app'
    if [[ -d "$app" ]]; then
        source "$(dirname "$0")/installation-common.sh"
        buddy_check_bundle "$app" com.zfdang.voice-input-buddy
        if [[ "$(/usr/libexec/PlistBuddy -c 'Print :BuddySupportsUninstallPreparation' "$app/Contents/Info.plist" 2>/dev/null || true)" == true ]]; then
            if /usr/bin/codesign --verify --deep --strict "$app" 2>/dev/null; then
                if ! "$app/Contents/MacOS/VoiceInputBuddy" --unregister-login-item; then
                    echo 'Warning: login-item removal failed; continuing uninstall. Check Login Items in System Settings.' >&2
                fi
            else
                echo 'Skipping login-item preparation: app signature is invalid.' >&2
            fi
        fi
    fi
    ;;
cleanup)
    /usr/bin/defaults delete com.zfdang.voice-input-buddy >/dev/null 2>&1 || true
    source "$(dirname "$0")/installation-common.sh"
    buddy_cleanup_user_data "$HOME"
    ;;
*) echo 'Expected prepare or cleanup.' >&2; exit 2 ;;
esac
