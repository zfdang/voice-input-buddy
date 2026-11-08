#!/usr/bin/env python3
"""Generate icon resources from the supplied artwork with transparent backgrounds."""
from pathlib import Path
from PIL import Image
import subprocess

root = Path(__file__).resolve().parent.parent
resources = root / 'Resources'
artwork = resources / 'IconArtwork'
iconset = resources / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)

# 1. App Icon
app = Image.open(artwork / 'app.png')
app_1024 = app.resize((1024, 1024), Image.Resampling.LANCZOS)
app_1024.save(resources / 'AppIcon.png')
pages_app_icon = root / 'pages' / 'assets' / 'app-icon.png'
if pages_app_icon.parent.exists():
    app_1024.save(pages_app_icon)

for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        app.resize((size * scale, size * scale), Image.Resampling.LANCZOS).save(iconset / f'icon_{size}x{size}{suffix}.png')
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)

# 2. Status Icons (Menubar)
status_sources = [
    (Image.open(artwork / filename), name)
    for filename, name in (('status.png', 'StatusIconTemplate'), ('status-active.png', 'StatusIconActiveTemplate'))
]

# Use one crop for both states so the artwork stays in the same position.
# Crop tightly around the subject across both states to maximize subject size on the menu bar.
boxes = [image.getchannel('A').point(lambda value: 255 if value >= 10 else 0).getbbox()
         for image, _ in status_sources]
left = min(box[0] for box in boxes)
top = min(box[1] for box in boxes)
right = max(box[2] for box in boxes)
bottom = max(box[3] for box in boxes)
side = max(right - left, bottom - top)
center_x, center_y = (left + right) // 2, (top + bottom) // 2
crop = (center_x - side // 2, center_y - side // 2,
        center_x - side // 2 + side, center_y - side // 2 + side)

for source, name in status_sources:
    cropped = source.crop(crop)
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        cropped.resize((22 * scale, 22 * scale), Image.Resampling.LANCZOS).save(resources / f'{name}{suffix}.png')
