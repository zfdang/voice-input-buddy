#!/usr/bin/env python3
"""Generate icon resources by resizing the supplied artwork."""
from pathlib import Path
from PIL import Image
import subprocess

root = Path(__file__).resolve().parent.parent
resources = root / 'Resources'
artwork = resources / 'IconArtwork'
iconset = resources / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
app = Image.open(artwork / 'app.jpg').convert('RGB')
app.save(resources / 'AppIcon.png')
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        app.resize((size * scale, size * scale), Image.Resampling.LANCZOS).save(iconset / f'icon_{size}x{size}{suffix}.png')
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)

for filename, name in (('status.jpg', 'StatusIconTemplate'), ('status-active.jpg', 'StatusIconActiveTemplate')):
    source = Image.open(artwork / filename).convert('RGB')
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        source.resize((18 * scale, 18 * scale), Image.Resampling.LANCZOS).save(resources / f'{name}{suffix}.png')
