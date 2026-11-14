# Virtual Microphone Setup

## 1. How It Works & Device Details
Remote Buddy uses an independent two-channel virtual microphone driver built from BlackHole v0.7.1, named **Remote Buddy Mic** with UID `BuddyMic2ch_UID`.
- Remote Buddy always outputs Bluetooth remote voice audio to **Remote Buddy Mic**, with no other output choices or BlackHole fallback.
- This driver is completely standalone and does not replace or interfere with any existing BlackHole or third-party audio drivers on your Mac.

## 2. Installation
- Download the installer from this project's GitHub Releases (`*_macOS_arm64.pkg` for Apple Silicon or `*_macOS_intel.pkg` for Intel). One package installs both the app and the virtual microphone driver together.
- **Install locations**: The app is installed to `/Applications/Remote Buddy.app` and the driver to `/Library/Audio/Plug-Ins/HAL/RemoteBuddyMic.driver`.
- **Notes**: Installation requires administrator authorization and restarts macOS Core Audio, briefly interrupting playback or recording. After pairing and button testing, the first-run guide automatically verifies that both the driver and output are ready. If the device does not appear, click Refresh or restart your Mac as prompted.

## 3. Using It in Your Voice Input Tool
1. In WeType, Doubao, Voice Buddy, NetEase Bageshuo, Typeless, macOS Dictation, or another voice input tool, select **Remote Buddy Mic** as the microphone and configure its voice shortcut following the guide.
2. Adjust each remote's microphone gain individually on the Remote Connection page if needed.
3. To test, click into any focused text field, then hold the voice button to speak and release when done (or use your configured tap gesture) to confirm voice recognition and text entry work.

## 4. Signing & Source Code
Current installer PKGs are unsigned and not notarized. The app and driver use a fixed self-signed certificate; online update packages also require this project's Sparkle signature. Matching driver source code, patches, and licenses are available at: https://github.com/zfdang/remote-buddy/blob/main/docs/source-code.md .

## 5. Uninstalling
To uninstall, download the universal uninstaller PKG and open it in macOS Installer. By default it removes the app, virtual microphone driver, and your settings, logs, and caches (you may uncheck personal-data removal during installation). Uninstalling requires administrator authorization and restarts Core Audio. Details: https://github.com/zfdang/remote-buddy/blob/main/docs/uninstall.md .
