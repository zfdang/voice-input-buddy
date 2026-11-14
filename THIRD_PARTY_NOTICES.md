# Third-party notices

## Current distribution

Remote Buddy bundles its app and the independently named RemoteBuddyMic driver in one PKG. Driver sources are BlackHole v0.7.1 with `third_party/blackhole/device-usb.patch`. Matching project source and the `_sources.tar.gz` archive (including pinned `BlackHole` and `Sparkle` sources) are published alongside each release on GitHub (<https://github.com/zfdang/remote-buddy/releases>) and documented in <https://github.com/zfdang/remote-buddy/blob/main/docs/source-code.md>. RC003 product photos, upstream proprietary artwork, libopus binaries and private extensions are not distributed. The historical descriptions below do not imply they are bundled or supported.

## Sparkle

- Source: <https://github.com/sparkle-project/Sparkle>
- Version: 2.9.4 / `b6496a74a087257ef5e6da1c5b29a447a60f5bd7`
- License: MIT, with the external license notices reproduced below

The bundled framework's complete license and external notices follow, copied from the pinned Sparkle 2.9.4 distribution. This notice file is included in the app's Resources directory. Matching source is published in each release's `_sources.tar.gz` archive and linked in <https://github.com/zfdang/remote-buddy/blob/main/docs/source-code.md>. No upstream feed or signing key is reused.

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## open-voice-bridge

- Project: `nijez/open-voice-bridge`
- Source: <https://github.com/nijez/open-voice-bridge>
- License: GNU General Public License v3.0 only (`GPL-3.0-only`)

`remote-mic-app` was derived from `open-voice-bridge`. CoreBluetooth peripheral lifecycle handling, initial ATVV service discovery, and audio streaming flow originated from this repository.

## remote-mic-app

- Source: <https://github.com/HD838A/remote-mic-app>
- Imported revision: `cae2a23804506538c31003d14ec3239379da66c1`
- License: GPL-3.0-only
- Upstream copyright: `Copyright (C) 2026 SayAll contributors` (SayAll / HD838A)

Remote Buddy is an independent derivative. Original upstream copyright notices are preserved verbatim below and in <https://github.com/zfdang/remote-buddy/blob/main/docs/upstream-copyright.md>. The sections below preserve the upstream component inventory and historical descriptions; disabled components are not necessarily included in the macOS app bundle. No upstream proprietary artwork is included. See <https://github.com/zfdang/remote-buddy/blob/main/docs/provenance.md> for actual build and distribution requirements.

```text
Copyright (C) 2026 SayAll contributors
Upstream project: https://github.com/HD838A/remote-mic-app
Adapted from GPL-3.0-only project xxb26553663-star/remote-bridge-hub (commit 8a93f321ac71a602300c6cd77f7256fa4b63068e).
Software code licensed under GPL-3.0-only.
```

## remote-bridge-hub

- Project: `xxb26553663-star/remote-bridge-hub`
- Source: <https://github.com/xxb26553663-star/remote-bridge-hub>
- Reference revision: `8a93f321ac71a602300c6cd77f7256fa4b63068e`
- License: GNU General Public License v3.0 only (`GPL-3.0-only`)

The Xiaomi RC003 ATVV UUIDs, microphone command behavior, IMA/DVI ADPCM decoding order, capability parsing, and HID usage mapping were adapted from this project. The macOS implementation uses Apple public frameworks and does not include the upstream Windows injection, VB-CABLE packaging, commercial branding, or customer systems.

## mi_remote_control

- Project: `godarrenw/mi_remote_control`
- Source: <https://github.com/godarrenw/mi_remote_control>
- License: MIT

Xiaomi remote control Bluetooth protocol analysis and key code identification were informed by this project.

## codex-siri-remote

- Project: `luobosibing2/codex-siri-remote`
- Source: <https://github.com/luobosibing2/codex-siri-remote>
- Reference revision: `3da8bc74cc840c3e048448de203586cd24108f6a`
- License: GNU General Public License v3.0 or later (`GPL-3.0-or-later`)

The Apple Siri Remote A2854 vendor/product identifiers, HID usage table, and initial circular-scroll tuning were informed by this project. The current implementation uses public Apple frameworks and does not include the upstream private touch adapter, DriverKit components, or virtual audio implementation.

## SiriRemoteForge

- Project: `HOLODATA-COM/SiriRemoteForge`
- Source: <https://github.com/HOLODATA-COM/SiriRemoteForge>
- Reference revision: `10581a960f0738e36516defb79db24b18df214d3`
- License: GNU General Public License v3.0 or later (`GPL-3.0-or-later`)

The lossless PacketLogger file-tail capture shape, binary `.pklg` record layout, ACL/L2CAP fragmentation handling, A2854 voice notification framing, Opus packet handling, and packet-loss concealment strategy were informed by this project. The upstream remote-mic-app implementation uses its `MiRemoteV 2ch` output instead of including SiriRemoteForge's HAL driver, root LaunchDaemon, shared-memory ring, application UI, or built-in microphone fallback.

## iRemote A2854

- Project: `DaviBaum/iRemote-A2854`
- Source: <https://github.com/DaviBaum/iRemote-A2854>
- Reference revision: `3f6fd807a6b11df12789df3fdd5874ad9336a684`
- License: MIT

The direct `com.apple.bluetooth.BTPacketLogger` XPC connection, `RequiresAuth` / `Authentication` handshake, `com.apple.PacketLogger.HCI` Authorization Services flow, profile-required diagnostic recognition, and bounded in-memory traffic handling were informed by this project. The upstream remote-mic-app implementation provides a narrowly scoped client and does not include iRemote's Whisper transcription, text insertion, pointer control, UI, model management, or user data handling.

## Opus

- Project: Opus Interactive Audio Codec
- Source: <https://www.opus-codec.org/>
- Historical upstream version: 1.6.1; no libopus binary is bundled in this distribution
- License: BSD 3-Clause (`BSD-3-Clause`)

The historical Apple Remote audio helper could dynamically load an externally installed libopus to decode remote voice packets. That helper and the PacketLogger/HCI capture implementation have been removed. This product does not bundle libopus or Apple PacketLogger; Apple Siri Remote remains unsupported in the app. The copyright and license below are retained as historical notices.

Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo, Mozilla, Amazon

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
- Neither the name of Internet Society, IETF or IETF Trust, nor the names of specific contributors, may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## BlackHole

- Project: `ExistentialAudio/BlackHole`
- Source: <https://github.com/ExistentialAudio/BlackHole>
- Pinned source revision: `v0.7.1` / `e2b22aaaba4e507a097131704bf96dabc004d9cf`
- Copyright: Copyright (C) 2019 Existential Audio Inc.
- License: GNU General Public License v3.0 (`GPL-3.0`)
- Bundled driver license: `Contents/Resources/BlackHole-LICENSE` inside `RemoteBuddyMic.driver`

`scripts/build-driver.sh` and `third_party/blackhole/device-usb.patch` build the independent `RemoteBuddyMic.driver` from pinned BlackHole source. The app routes audio only to this driver, not to an optional BlackHole device. The driver uses USB transport, its own CFPlugIn factory UUID, bundle identifier and BuddyMic UID. It does not replace an installed BlackHole or MiRemoteV driver. The release PKG installs both the app and RemoteBuddyMic; matching driver source is available at the pinned upstream revision together with this repository’s patch and build script. The complete upstream license text is bundled within the driver at `Contents/Resources/BlackHole-LICENSE`. "BlackHole" is a trademark of Existential Audio Inc.; the name is used here strictly to identify the origin of the upstream codebase.

## MiRemoteVoice

- Project: `VincentKingHsu/MiRemoteVoice`
- Source: <https://github.com/VincentKingHsu/MiRemoteVoice>
- Reference release: `v1.0.0-beta.1`
- Application license: MIT

The Doubao compatibility design is informed by MiRemoteVoice: a side-by-side BlackHole-derived device reports its actual audio Device as USB transport so Doubao can enumerate it. This fork reimplements that idea as a pinned, source-built BlackHole patch instead of reusing MiRemoteVoice's version-specific binary replacement script.

## RC003 product photo

The upstream project included an RC003 product photo. That photo and upstream proprietary app artwork are not included in Remote Buddy. The button mapping interface uses the original `BuddyRemoteIllustration.png` schematic.

## Setup guide screenshots

`Resources/Onboarding` includes inherited light/dark setup screenshots from remote-mic-app (SayAll contributors), under the upstream project license, and locally captured or rendered replacement/additional light screenshots for WeType, Doubao, Bageshuo, and Voice Buddy. They illustrate third-party and macOS settings; depicted interface copyrights and trademarks remain with their respective owners. The upstream proprietary app logo and remote product photo are not bundled. `BuddyRemoteIllustration.png` is an unbranded generated product render. `scripts/generate-remote-layout-reference.swift` produces its coordinate reference, not the shipped image. The artwork uses no manufacturer logos or downloaded product photos.

## Public Google remote protocol references

The G9N9N adapter is implemented in this repository using public CoreBluetooth and IOKit APIs. No upstream private Google/Apple package, Windows injection code, or Linux audio backend is bundled.

- Source: <https://github.com/b0o/ATVVoice>; reference commit `0e8f6413dc4bad7a04e3c6b648945439d7a22fac`.
- Source: <https://github.com/Tilkmilk/vibe-mote>; reference commit `fb30e479694524962512b5bba6afc76cd0a04778`.
- Source: <https://github.com/81199000/mi-remote-mapper>; reference commit `8436d19b3932863bfa27583e0d4007020e85d7da`.
- Source: <https://github.com/fanxeon/mi-ao>; reference commit `d6019bcede80ff71d225385b5c44b6f5f84a4832`.

ATVVoice informs ATVV v1.0 control layout, ADPCM ordering, and session keepalive. vibe-mote informs the G9N9N Consumer Control usage table and compatibility diagnostics. mi-remote-mapper (MIT) and mi-ao (MIT) are architecture references only; their code is not imported. The following MIT notices are retained for the adapted protocol references.

### ATVVoice

MIT License

Copyright (c) 2026 Maddison Cohodas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### vibe-mote

MIT License

Copyright (c) 2026 VibeMote contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## Trademarks & Non-Affiliation

Remote Buddy is an independent open-source project licensed under GNU General Public License v3.0 only (`GPL-3.0-only`). It is not affiliated with, endorsed by, or sponsored by IOSPIRIT GmbH, Apple Inc., Google LLC, Xiaomi Corporation, or Existential Audio Inc. All third-party product names, hardware names, and trademarks belong to their respective owners and are used strictly for identification and compatibility descriptions.
