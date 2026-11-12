# Remote illustrations

These four SVG files are original schematic drawings distributed under the
project's GPL-3.0-only license. Matching transparent PNGs in the parent directory
are the app's thumbnails. They contain no copied manufacturer photographs,
logos, or traced image paths. Buttons use generic symbols or short text labels.

The Siri drawing depicts the third-generation USB-C remote (A2854); it does not
claim that all Siri Remote generations share its layout. Google replacement
units may have different layouts. These drawings are not to scale and do not
establish connection or audio compatibility.

Official visual and button-layout references:

- [Chromecast Voice Remote G9N9N](https://support.google.com/chromecast/answer/10116742?hl=en)
- [Google TV Streamer Voice Remote GY3LE](https://support.google.com/googletv/answer/15323195?hl=en)
- [Siri Remote third-generation USB-C](https://support.apple.com/en-us/111844)
  and [model identification](https://support.apple.com/en-au/103233)

Manufacturer images remain on their official sites and are not included in the distribution.

`T1RemoteIllustration.svg` provides the editable geometric front layout for `T1-Remote`, paired with original GPL-3.0-only studio renders (`T1RemoteIllustration.png` for the button-mapping canvas and `T1RemoteSetupIllustration.png` combining front and rear QWERTY layouts for device setup).

To regenerate a thumbnail from its editable vector source, from the repo root:

```sh
rsvg-convert Resources/RemoteIllustrations/ChromecastG9N9NIllustration.svg -o Resources/ChromecastG9N9NIllustration.png
rsvg-convert Resources/RemoteIllustrations/GoogleStreamerGY3LEIllustration.svg -o Resources/GoogleStreamerGY3LEIllustration.png
rsvg-convert Resources/RemoteIllustrations/SiriRemoteA2854Illustration.svg -o Resources/SiriRemoteA2854Illustration.png
rsvg-convert Resources/RemoteIllustrations/T1RemoteIllustration.svg -o Resources/T1RemoteIllustration.png
```

`rsvg-convert` is only an artwork regeneration tool; normal application builds
use the checked-in PNGs and do not require it.

The Xiaomi schematic is generated from the AppKit drawing source rather than an
SVG. Its 508 × 1030 canvas and normalized button centers must match
`RemoteMappingLayout`; preserve the native aspect ratio when rendering it.
After changing the drawing, regenerate the PNG and check the mapping page:

```sh
swift scripts/generate-remote-layout-reference.swift Resources/BuddyRemoteIllustration.png
```
