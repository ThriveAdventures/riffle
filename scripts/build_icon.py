#!/usr/bin/env python3
"""Build AppIcon.icns from a square icon artwork PNG.

Usage: python3 scripts/build_icon.py <artwork.png> [output.icns]

Takes artwork of a full-bleed tile (or a tile on a white background, as
image models tend to produce), crops it, masks it to the macOS rounded
square, composites the standard 824px tile on a 1024px canvas with a soft
drop shadow, and emits a .icns. Requires Pillow (pip install pillow) and
iconutil (macOS).

The icon's design source of truth is logos/iterations/iteration-2.svg;
render it (or its material-pass PNG) and feed the result to this script.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageOps

def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    src_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("assets/AppIcon.icns")

    src = Image.open(src_path).convert("RGB")

    # Crop the tile off any white canvas: bbox of clearly-non-white pixels.
    gray = src.convert("L")
    mask = gray.point(lambda p: 255 if p < 235 else 0)
    bbox = mask.getbbox()
    tile = src.crop(bbox) if bbox else src
    side = min(tile.size)
    tile = ImageOps.fit(tile, (side, side), centering=(0.5, 0.5))

    # Shave any painted edge bevel off the artwork (image models like to
    # frame the tile in bright trim that reads badly once masked), then a
    # controlled hairline is added back below.
    inset = int(side * 0.05)
    tile = tile.crop((inset, inset, side - inset, side - inset))
    side = tile.size[0]

    # Apple icon grid: 824px tile centered on a 1024 canvas.
    TILE, CANVAS = 824, 1024
    tile = tile.resize((TILE, TILE), Image.LANCZOS)
    radius = int(TILE * 0.225)

    corner = Image.new("L", (TILE, TILE), 0)
    d = ImageDraw.Draw(corner)
    d.rounded_rectangle([0, 0, TILE - 1, TILE - 1], radius=radius, fill=255)
    tile_rgba = tile.convert("RGBA")
    tile_rgba.putalpha(corner)

    stroke = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    sd0 = ImageDraw.Draw(stroke)
    sd0.rounded_rectangle([1, 1, TILE - 2, TILE - 2], radius=radius,
                          outline=(255, 255, 255, 30), width=3)
    tile_rgba.alpha_composite(stroke)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    off = (CANVAS - TILE) // 2
    sd.rounded_rectangle([off, off + 14, off + TILE, off + TILE + 14],
                         radius=radius, fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(tile_rgba, (off, off))

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in [16, 32, 128, 256, 512]:
            canvas.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            canvas.resize((size * 2, size * 2), Image.LANCZOS).save(
                iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out_path)],
                       check=True)
    print(f"wrote {out_path}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
