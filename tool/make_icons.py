"""Draws the SpoolBuddy logo and writes the Android launcher icons.

    python tool/make_icons.py

Writes adaptive icon layers (foreground, monochrome for themed icons), legacy
square icons for each density, and docs/logo.png for the README. Needs Pillow.
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"

BG = (26, 26, 26, 255)  # kiosk background #1A1A1A
GREEN = (0, 174, 66, 255)  # Bambu green #00AE42
GREEN_DARK = (0, 120, 46, 255)
MINT = (159, 242, 191, 255)  # #9FF2BF, the app's on-green text colour
SS = 4  # supersampling for smooth edges


def foreground(size: int, mono: bool = False) -> Image.Image:
    """The spool and NFC waves on a transparent 108dp adaptive-icon canvas."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)
    cx, cy = 0.45 * s, 0.53 * s

    def circle(r, fill=None, outline=None, width=0):
        d.ellipse((cx - r * s, cy - r * s, cx + r * s, cy + r * s), fill=fill, outline=outline, width=int(width * s))

    def arc(r, start, end, color, width):
        box = (cx - r * s, cy - r * s, cx + r * s, cy + r * s)
        d.arc(box, start, end, fill=color, width=int(width * s))
        # Round caps.
        # PIL strokes arcs inward from the radius, so the caps sit half a stroke in.
        rc = (r - width / 2) * s
        for a in (start, end):
            x = cx + rc * math.cos(math.radians(a))
            y = cy + rc * math.sin(math.radians(a))
            w = width * s / 2
            d.ellipse((x - w, y - w, x + w, y + w), fill=color)

    if mono:
        # Themed icons are a single-colour silhouette: spool with a hub hole, and waves.
        circle(0.20, fill=white)
        for r in (0.165, 0.13):
            circle(r, outline=(0, 0, 0, 0), width=0.012)
        circle(0.075, fill=(0, 0, 0, 0))
        circle(0.045, fill=white)
        circle(0.025, fill=(0, 0, 0, 0))
        for r in (0.255, 0.305):
            arc(r, -64, -22, white, 0.028)
        return img.resize((size, size), Image.LANCZOS)

    circle(0.20, fill=GREEN)  # flange
    for r in (0.165, 0.13):  # filament windings
        circle(r, outline=GREEN_DARK, width=0.012)
    circle(0.075, fill=BG)  # hub
    circle(0.045, fill=MINT)
    circle(0.025, fill=BG)
    for r in (0.255, 0.305):  # NFC waves
        arc(r, -64, -22, MINT, 0.028)
    return img.resize((size, size), Image.LANCZOS)


def legacy(size: int) -> Image.Image:
    """Square icon with rounded corners: the middle 72dp of the adaptive icon on the background."""
    canvas = int(size * 108 / 72)
    full = Image.new("RGBA", (canvas, canvas), BG)
    full.alpha_composite(foreground(canvas))
    off = (canvas - size) // 2
    icon = full.crop((off, off, off + size, off + size))
    mask = Image.new("L", (size * SS, size * SS), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * SS - 1, size * SS - 1), radius=int(size * SS * 0.22), fill=255)
    icon.putalpha(mask.resize((size, size), Image.LANCZOS))
    return icon


DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

for name, scale in DENSITIES.items():
    folder = RES / f"mipmap-{name}"
    folder.mkdir(parents=True, exist_ok=True)
    legacy(int(48 * scale)).save(folder / "ic_launcher.png")
    foreground(int(108 * scale)).save(folder / "ic_launcher_foreground.png")
    foreground(int(108 * scale), mono=True).save(folder / "ic_launcher_monochrome.png")

anydpi = RES / "mipmap-anydpi-v26"
anydpi.mkdir(exist_ok=True)
(anydpi / "ic_launcher.xml").write_text(
    """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
""",
    encoding="utf-8",
)
(RES / "values/ic_launcher_background.xml").write_text(
    """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#1A1A1A</color>
</resources>
""",
    encoding="utf-8",
)

docs = ROOT / "docs"
docs.mkdir(exist_ok=True)
legacy(512).save(docs / "logo.png")
print("icons written")
