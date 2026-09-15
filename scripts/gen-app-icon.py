#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Regenerate swift/MaxPane/Resources/AppIcon.icns from AppIcon-source.png.

macOS 26 draws every app icon inside its own squircle with a glass rim. An
icon that is an opaque full-bleed square gets clipped to that shape and the
rim is painted over the cut, which on a dark ground shows up as a pale ring
and light corners. The fix is to hand the system an icon that already has
the shape: the artwork masked to Apple's squircle, occupying 824 of 1024
points, centred on a transparent canvas.

    ./scripts/gen-app-icon.py

The output is committed; nothing in the build runs this.
"""
import subprocess, tempfile
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "swift/MaxPane/Resources/AppIcon-source.png"
OUT = ROOT / "swift/MaxPane/Resources/AppIcon.icns"

CANVAS = 1024
ART = 824            # Apple's icon grid: the squircle spans 824/1024
RADIUS = ART * 0.2237  # continuous-corner radius as a fraction of the side
SUPER = 4            # supersample the mask for a clean anti-aliased edge

SIZES = [16, 32, 128, 256, 512]


def squircle_mask(size: int) -> Image.Image:
    big = size * SUPER
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (0, 0, big - 1, big - 1), radius=RADIUS * SUPER, fill=255
    )
    return m.resize((size, size), Image.LANCZOS)


def main() -> None:
    art = Image.open(SRC).convert("RGBA").resize((ART, ART), Image.LANCZOS)
    art.putalpha(squircle_mask(ART))
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - ART) // 2
    canvas.paste(art, (off, off), art)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for s in SIZES:
            canvas.resize((s, s), Image.LANCZOS).save(iconset / f"icon_{s}x{s}.png")
            canvas.resize((s * 2, s * 2), Image.LANCZOS).save(iconset / f"icon_{s}x{s}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
