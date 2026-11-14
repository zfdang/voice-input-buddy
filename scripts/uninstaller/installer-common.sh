#!/bin/bash
set -euo pipefail
# Installer runs as root; personal actions run only as the console account.
[[ "$(/usr/bin/id -u)" == 0 ]] || { echo 'Administrator authorization required.' >&2; exit 1; }
[[ "${3:-/}" == / ]] || { echo 'Uninstall only supports the running system volume.' >&2; exit 1; }
buddy_user="$(/usr/bin/stat -f '%Su' /dev/console)"
[[ "$buddy_user" != root && "$buddy_user" != loginwindow ]] || { echo 'Log in to your desktop before uninstalling.' >&2; exit 1; }
buddy_uid="$(/usr/bin/id -u "$buddy_user")"
buddy_home="$(/usr/bin/dscl . -read "/Users/$buddy_user" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: //')"
[[ "$buddy_home" == /* && "$buddy_home" != / && -d "$buddy_home" ]] || { echo 'Cannot identify the user home directory.' >&2; exit 1; }
buddy_run_user() {
    /bin/launchctl asuser "$buddy_uid" /usr/bin/sudo -u "$buddy_user" /usr/bin/env HOME="$buddy_home" /bin/bash "$(dirname "$0")/uninstall-user.sh" "$1"
}
