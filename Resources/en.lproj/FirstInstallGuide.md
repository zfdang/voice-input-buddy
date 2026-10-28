# First setup

Download the PKG for your Mac architecture from this project's GitHub Releases. It installs both the app and microphone driver. Open `/Applications/Voice Input Buddy.app`.

The initial guide follows Permissions, Prepare Device, Connect Remote, Button Test, Driver Check, Input Tool, Voice Test, and Complete. Grant Bluetooth, Input Monitoring, and Accessibility permissions as requested. Xiaomi RC001/RC003 and G9N9N have connection adapters; GY3LE and Siri Remote adapters remain incomplete.

**G9N9N currently has partial voice support; control-button mapping is unsupported.** For the initial OK check, press OK + Up together. In the later button test, press OK + Up and then Back + Up, releasing both after each pair, to reach three distinct detected buttons and continue. These checks do not establish usable control-button mapping. The voice button and microphone can still be used afterward. After setup, OK + any direction offers an experimental Enter action when mapping is enabled and the app has exclusive access; all four directions were tested on the A0 / firmware 26.7 unit. See the [standalone test report](https://github.com/zfdang/voice-input-buddy/blob/main/docs/g9n9n-compatibility.md) (Chinese).

The app automatically routes audio to **Voice Input Buddy Mic**, without a loopback output picker. Select that microphone in your input tool, then configure and test its voice shortcut. Buddy routes audio and buttons; your input tool performs recognition. Buddy does not collect usage statistics, save recordings or transcript history, or upload logs.

Driver installation requires administrator authorization and briefly restarts audio. Current PKGs are unsigned and not notarized; the app and driver use a fixed self-signed identity. Windows is not implemented. More information: https://github.com/zfdang/voice-input-buddy/blob/main/docs/interface.md
