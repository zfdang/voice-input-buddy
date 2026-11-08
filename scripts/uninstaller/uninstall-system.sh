#!/bin/bash
set -euo pipefail
[[ "$(/usr/bin/id -u)" == 0 ]] || { echo 'Administrator authorization required.' >&2; exit 1; }
source "$(dirname "$0")/installation-common.sh"
app='/Applications/Remote Buddy.app'
driver='/Library/Audio/Plug-Ins/HAL/RemoteBuddyMic.driver'
# Preflight every identity before deleting any bundle.
buddy_check_bundle "$app" com.zfdang.remote-buddy
buddy_check_bundle "$driver" com.zfdang.remote-buddy.mic
had_driver=false
[[ ! -e "$driver" ]] || had_driver=true
buddy_remove_bundle "$app" com.zfdang.remote-buddy
buddy_remove_bundle "$driver" com.zfdang.remote-buddy.mic
/usr/sbin/pkgutil --forget com.zfdang.remote-buddy.installer >/dev/null 2>&1 || true
/usr/sbin/pkgutil --forget com.zfdang.remote-buddy.mic.installer >/dev/null 2>&1 || true
if "$had_driver" && /usr/bin/pgrep -x coreaudiod >/dev/null; then
    /usr/bin/killall coreaudiod || { echo 'Driver removed; restart your Mac to finish unloading it.' >&2; }
fi
