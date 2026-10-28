# Voice Input Buddy

[简体中文](README.md) | **English**

Turn a remote control into a voice-input button for your computer. Press to talk, release to finish, and let your preferred input method or dictation tool enter text into the current field.

[Website](https://voice.zfdang.com/index.en.html) · [Downloads](https://github.com/zfdang/voice-input-buddy/releases)

Supports **macOS 14 and later**, on Apple Silicon and Intel Macs. Windows support is planned.

## What can it do?

- Use a remote's microphone for voice input, without reaching for the keyboard.
- Map Xiaomi remote control buttons to keyboard shortcuts, application actions, or common phrases. Phrase content can mix languages and stays the same when the interface language changes.
- Configure hold-to-talk or press-to-start/stop behavior for your input tool.
- Set up permissions, the microphone driver, device connection, and input integration in one guide.

Voice Input Buddy does not collect usage statistics, save recordings or transcript history, or upload logs. Recognition and text cleanup are handled by your selected input tool, with that tool's own network and privacy settings.

## How does it work?

```text
Remote microphone → Bluetooth audio → Voice Input Buddy → Virtual microphone → Input tool
Remote voice button → Voice Input Buddy → Voice shortcut → Text in the current field
```

The app decodes remote audio and sends it to a virtual microphone while triggering the selected tool's voice shortcut. It connects hardware to input software; it does not run its own speech-recognition model. Live transcription, recognition speed, and corrections depend on the input tool.

## How do I use it?

Download `Voice_Input_Buddy_*.pkg` from [Releases](https://github.com/zfdang/voice-input-buddy/releases). One installer includes both the app and its virtual microphone driver.

1. Install and open `/Applications/Voice Input Buddy.app`.
2. Follow the guide to grant Bluetooth, Input Monitoring, and Accessibility permissions. The app follows your system language by default; you can choose English or Chinese on the first screen.
3. Select and connect your remote, test its buttons, and wait for the driver and fixed output checks to pass. Select **Voice Input Buddy Mic** in your input tool. The app uses this device automatically, without an output picker or fallback to BlackHole or speakers.
4. Configure the tool's voice shortcut under **Integration**, then test it with the guide.
5. Focus a text field, press the voice button to speak, and release to finish. Adjust the trigger behavior for tools that use separate start/stop taps.

Configure control buttons for supported devices under **Buttons**. To check the setup again, use **Run Setup Guide Again** at the top of Settings. G9N9N currently has partial voice support and **does not support control-button mapping**. For its initial OK check, press OK + Up together; in the later button test, also press Back + Up together to reach three distinct buttons and continue voice setup. Release both after each pair. This method is only for setup checks. See [G9N9N voice support and button-mapping limitations](docs/g9n9n-compatibility.md) (Chinese).

Driver installation requires administrator authorization and briefly interrupts audio. Current installers are not Apple-notarized and may be blocked by macOS. See [installation and release notes](docs/releases.md).

## Which devices are supported?

| Device | Status |
| --- | --- |
| Xiaomi Bluetooth Remote 2 / 2 Pro | RC001 = 2; RC003 = 2 Pro. Both have ATVV and button adapters. 2 Pro buttons tested locally and audio confirmed by the user; complete Remote 2 audio acceptance is pending |
| Google Chromecast Voice Remote (G9N9N) | **Partial support: voice button and microphone tested working; control-button mapping is unsupported.** The A0 / firmware 26.7 unit sends single-key and release reports shorter than its descriptor requires. Occasional two-key input does not establish usable controls; other units require separate validation. See the [standalone test report](docs/g9n9n-compatibility.md) (Chinese) |
| Google TV Streamer Voice Remote (GY3LE) | Planned; adapter implementation and hardware validation pending |
| Apple Siri Remote | Planned; adapter implementation and hardware validation pending |

The device scope is limited to these four entries. Google hardware model numbers follow [Google's regulatory documentation](https://support.google.com/product-documentation/answer/4541589?hl=en). Third-party replacements require separate validation; a seller's “compatible with G9N9N” label does not establish support.

Bluetooth pairing alone does not establish compatibility: the remote must use a supported button and audio protocol.

## Which input methods and tools can I use?

| Tool | Integration |
| --- | --- |
| WeType / WeChat Input Method | Dedicated setup entry with virtual microphone and voice shortcut |
| Doubao Input Method | Dedicated setup entry with hold and tap behavior |
| NetEase Bageshuo | Dedicated setup entry with voice shortcut and microphone configuration |
| Typeless | Configure its voice shortcut and start/stop behavior |
| VoiceCursor | Separate entry using the virtual microphone and a custom voice shortcut |
| macOS Dictation | Built in, no third-party app; set the shortcut to Press 🌐 Twice. Holding the remote presses Fn twice to start, and releasing it presses Fn once to stop |
| Other voice-input tools | Configure a custom shortcut under Other Tools |

The tool must accept the virtual microphone and expose a usable voice shortcut. Versions and settings vary: verify the actual behavior with the guide. A configuration entry does not mean every version has been tested.

## More information

- [Interface and troubleshooting](docs/interface.md)
- [Website and deployment](docs/website.md)
- [Development and builds](docs/development.md)
- [Builds and fixed signing certificates](docs/build-and-signing.md)
- [Releases and installers](docs/releases.md)
- [Architecture and scope](docs/architecture.md)
- [Privacy and testing](docs/privacy-and-testing.md)
- [Source provenance](docs/provenance.md), [GPL-3.0-only license](LICENSE), [third-party notices](THIRD_PARTY_NOTICES.md)

## Download and uninstall

Choose the `*_macOS_arm64.pkg` installer for Apple Silicon or `*_macOS_intel.pkg` for Intel. Each contains the app and its **Voice Input Buddy Mic** driver.

To uninstall, download `Voice_Input_Buddy_Uninstaller_*_macOS_universal.pkg` (works on both architectures) and open the package in macOS Installer. The default removes the app, driver, and your settings, logs and caches. Uncheck the personal-data removal option to retain settings and logs. Installer’s fixed **Install** button executes uninstall actions; no software is installed. Administrator authorization is required; audio briefly restarts. See [uninstallation details](docs/uninstall.md).

## References

| Project / module | Role |
| --- | --- |
| [remote-mic-app](https://github.com/HD838A/remote-mic-app) | Code foundation for remote connectivity, audio bridging, button mappings, and interface |
| [remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub) | Xiaomi ATVV protocol, ADPCM decoding, and HID mapping reference |
| [vibe-mote](https://github.com/Tilkmilk/vibe-mote) | Reference for Google TV / Chromecast remote HID buttons, ATVV audio, and third-party replacement differences (Windows implementation) |
| [ATVVoice](https://github.com/b0o/ATVVoice) | Linux implementation with verified G9N9N support; ATVV negotiation, synchronization, and keepalive reference |
| [mi-remote-mapper](https://github.com/81199000/mi-remote-mapper) | macOS CoreBluetooth, HID, and virtual audio reference; not G9N9N hardware acceptance evidence |
| [mi-ao](https://github.com/fanxeon/mi-ao) | macOS ATVV decoding and capability validation reference; Google remotes require hardware validation |
| [mi_remote_control](https://github.com/godarrenw/mi_remote_control) | Reference for button actions, application profiles, and troubleshooting |
| [open-voice-bridge](https://github.com/nijez/open-voice-bridge) | Reference for device capability modeling and audio-path diagnostics |
| [BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.1 | Virtual microphone driver |
| [MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) | USB-transport loopback compatibility design reference |
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.4 | macOS in-app updates with signed combined installers |
| [codex-siri-remote](https://github.com/luobosibing2/codex-siri-remote) | Historical reference for Apple remote HID and touch behavior |
| [SiriRemoteForge](https://github.com/HOLODATA-COM/SiriRemoteForge) | Historical reference for Apple remote audio and PacketLogger formats |
| [iRemote A2854](https://github.com/DaviBaum/iRemote-A2854) | Historical reference for Apple remote diagnostics and authorization |
| [Opus](https://www.opus-codec.org/) | Codec referenced by historical Apple remote compatibility code; its dynamic library is not included in the current installer |

Historical references do not imply current Apple remote support. See the [module inventory](docs/modules.md) for internal modules and macOS frameworks, and [third-party notices](THIRD_PARTY_NOTICES.md) for versions, copyrights, and licenses.
