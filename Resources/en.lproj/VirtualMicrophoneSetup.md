# Virtual microphone setup

Remote Buddy uses a separate two-channel driver built from BlackHole v0.7.1, named **Remote Buddy Mic** with UID `BuddyMic2ch_UID`. It does not replace an existing BlackHole or upstream application driver.

Download `*_macOS_arm64.pkg` for Apple Silicon or `*_macOS_intel.pkg` for Intel from this project's GitHub Releases. One package installs the app and driver; no separate driver build is needed. They install at `/Applications/Remote Buddy.app` and `/Library/Audio/Plug-Ins/HAL/RemoteBuddyMic.driver`. Installation requires administrator authorization and restarts Core Audio, briefly interrupting playback or recording. Refresh detection or restart your Mac as instructed if the device is not loaded.

The app always outputs to Remote Buddy Mic, without other output choices or a BlackHole fallback. After connection and button testing, the initial guide automatically checks the driver and output, proceeding only when both are ready. Select **Remote Buddy Mic** in Doubao, WeType or your other input tool and configure its voice shortcut with the guide. Adjust each remote's gain on the Devices page.

Verify recognition and text entry in a focused editable field, using hold-to-talk or the configured tap behavior. A successful build or device detection is not complete hardware acceptance.

Current PKGs are unsigned and not notarized. The app and driver use a fixed self-signed certificate; update packages also require this project's Sparkle signature. Matching driver source, patches and licenses: https://github.com/zfdang/remote-buddy/blob/main/docs/source-code.md . Local developers can still build a standalone driver package with `scripts/build-driver.sh` and `scripts/build-driver-package.sh`.

Download the universal uninstaller PKG and open it in macOS Installer. By default it removes the app, driver, and your settings, logs and caches; you may uncheck personal-data removal. Uninstall requires administrator authorization and restarts Core Audio. Details: https://github.com/zfdang/remote-buddy/blob/main/docs/uninstall.md .
