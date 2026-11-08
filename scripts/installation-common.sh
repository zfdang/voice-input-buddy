#!/bin/bash
# Shared by Installer and the standalone uninstaller. Only fixed product paths.
buddy_driver_fingerprint() {
    local driver="$1" details
    # Verify the executable and sealed resources before trusting the CodeDirectory
    # hash. This hash covers code/resources/requirements, but not signing timestamps.
    /usr/bin/codesign --verify --deep --strict "$driver" 2>/dev/null || return 1
    details="$(/usr/bin/codesign --display --verbose=4 "$driver" 2>&1)" || return 1
    /usr/bin/printf '%s\n' "$details" | /usr/bin/sed -nE 's/^CDHash=([0-9a-f]{40})$/\1/p'
}
buddy_check_bundle() {
    local path="$1" expected="$2"
    [[ -e "$path" || -L "$path" ]] || return 0
    [[ -d "$path" && ! -L "$path" ]] || { echo "Refusing unexpected bundle: $path" >&2; return 1; }
    local actual
    actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null)" || return 1
    [[ "$actual" == "$expected" ]] || { echo "Refusing unrelated bundle: $path" >&2; return 1; }
}
# Installation may repair unreadable product metadata at its fixed destination.
# Removal still requires a positively identified bundle via buddy_check_bundle.
buddy_check_install_target() {
    local path="$1" expected="$2" actual
    [[ -e "$path" || -L "$path" ]] || return 0
    [[ -d "$path" && ! -L "$path" ]] || return 1
    if actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null)"; then
        [[ "$actual" == "$expected" ]] || { echo "Refusing unrelated bundle: $path" >&2; return 1; }
    else
        echo "Repairing damaged bundle metadata: $path" >&2
    fi
}
buddy_remove_bundle() {
    buddy_check_bundle "$1" "$2" || return 1
    [[ -e "$1" ]] || return 0
    /bin/rm -rf -- "$1"
}
buddy_cleanup_user_data() {
    local user_home="${1:-}"
    [[ "$user_home" == /* && -d "$user_home" && ! -L "$user_home" ]] || return 1
    user_home="$(cd -- "$user_home" && /bin/pwd -P)" || return 1
    [[ "$user_home" != / ]] || return 1
    for path in \
        "$user_home/Library/Preferences/com.zfdang.voice-input-buddy.plist" \
        "$user_home/Library/Application Support/VoiceInputBuddy" \
        "$user_home/Library/Logs/VoiceInputBuddy" \
        "$user_home/Library/Caches/com.zfdang.voice-input-buddy" \
        "$user_home/Library/Saved Application State/com.zfdang.voice-input-buddy.savedState" \
        "$user_home/Library/Preferences/com.zfdang.remote-buddy.plist" \
        "$user_home/Library/Application Support/RemoteBuddy" \
        "$user_home/Library/Logs/RemoteBuddy" \
        "$user_home/Library/Caches/com.zfdang.remote-buddy" \
        "$user_home/Library/Saved Application State/com.zfdang.remote-buddy.savedState"; do
        /bin/rm -rf -- "$path"
    done
}
