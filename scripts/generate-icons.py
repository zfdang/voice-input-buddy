#!/usr/bin/env python3
"""Generate icon resources from the supplied artwork with transparent backgrounds."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageOps
import subprocess

root = Path(__file__).resolve().parent.parent
resources = root / 'Resources'
artwork = resources / 'IconArtwork'
iconset = resources / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
def remove_background(image, *, enclosed=False):
    image = image.convert('RGB')
    # JPEG backgrounds are near-white rather than a single exact white value.
    lightness = ImageOps.grayscale(image)
    if enclosed:
        alpha = ImageOps.invert(lightness).point(lambda value: min(255, value * 255 // 40))
    else:
        background = lightness.point(lambda value: 255 if value >= 235 else 0)
        # Keep white details enclosed by the colored artwork, such as the eyes.
        ImageDraw.floodfill(background, (0, 0), 128)
        alpha = background.point(lambda value: 0 if value == 128 else 255)
    image.putalpha(alpha)
    return image

app = remove_background(Image.open(artwork / 'app.jpg'))
app.save(resources / 'AppIcon.png')
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        app.resize((size * scale, size * scale), Image.Resampling.LANCZOS).save(iconset / f'icon_{size}x{size}{suffix}.png')
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)

for filename, name in (('status.jpg', 'StatusIconTemplate'), ('status-active.jpg', 'StatusIconActiveTemplate')):
    source = remove_background(Image.open(artwork / filename), enclosed=True)
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        source.resize((18 * scale, 18 * scale), Image.Resampling.LANCZOS).save(resources / f'{name}{suffix}.png')
