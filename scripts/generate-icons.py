#!/usr/bin/env python3
"""Generate app and menu bar icon resources from the supplied artwork."""
from pathlib import Path
from PIL import Image, ImageDraw
import subprocess

root = Path(__file__).resolve().parent.parent
resources = root / 'Resources'
artwork = resources / 'IconArtwork'
iconset = resources / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
app = Image.open(artwork / 'app.jpg').convert('RGBA')
mask = Image.new('L', app.size)
ImageDraw.Draw(mask).rounded_rectangle((40, 40, 983, 983), radius=212, fill=255)
app.putalpha(mask)
app.save(resources / 'AppIcon.png')
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        app.resize((size * scale, size * scale), Image.Resampling.LANCZOS).save(iconset / f'icon_{size}x{size}{suffix}.png')
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)

source = Image.open(artwork / 'status.png').convert('RGBA')
for scale in (1, 2):
    # Work at high resolution to preserve antialiased edges when reducing.
    canvas_size = 18 * 16
    base = Image.new('RGBA', (canvas_size, canvas_size))
    icon = source.resize((14 * 16, 14 * 16), Image.Resampling.LANCZOS)
    base.alpha_composite(icon, (0, 3 * 16))
    for active in (False, True):
        image = base.copy()
        if active:
            ImageDraw.Draw(image).ellipse((14 * 16, 1 * 16, 17 * 16, 4 * 16), fill=(0, 0, 0, 255))
        name = 'StatusIconActiveTemplate' if active else 'StatusIconTemplate'
        suffix = '@2x' if scale == 2 else ''
        image.resize((18 * scale, 18 * scale), Image.Resampling.LANCZOS).save(resources / f'{name}{suffix}.png')
