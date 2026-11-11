"""Brand assets for the Exa repo: light/dark BrightForge logos + a 1280x640 banner.

Usage: python tools/brand/make_banner.py .github/assets   (run exa_logo.py first)
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SRC = os.path.join(os.path.dirname(__file__), "brightforge-logo-source.png")
OUT = sys.argv[1]
FONTS = os.environ.get("FONTS_DIR", os.path.join(os.path.dirname(__file__), "fonts"))  # Sora + Manrope variable TTFs (OFL)
SORA = os.path.join(FONTS, "Sora%5Bwght%5D.ttf")
MANROPE = os.path.join(FONTS, "Manrope%5Bwght%5D.ttf")

TEAL = (53, 178, 190)
ORANGE = (194, 85, 28)
ORANGE_LIFT = (224, 122, 69)
SLATE = (15, 19, 22)
SLATE2 = (26, 33, 38)
CREAM = (242, 239, 233)
GREY = (174, 183, 188)

os.makedirs(OUT, exist_ok=True)

# ---- logos -------------------------------------------------------------
logo = Image.open(SRC).convert("RGBA")
bbox = logo.getbbox()
logo = logo.crop(bbox)


def dark_variant(im):
    """Black ring/bulb -> cream so the logo reads on dark backgrounds."""
    px = im.load()
    out = im.copy()
    po = out.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a and max(r, g, b) < 70:
                po[x, y] = (*CREAM, a)
    return out


def fit_width(im, w):
    return im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)


light = fit_width(logo, 640)
dark = dark_variant(light)
light.save(os.path.join(OUT, "brightforge-logo.png"), optimize=True)
dark.save(os.path.join(OUT, "brightforge-logo-dark.png"), optimize=True)


# ---- banner ------------------------------------------------------------
def font(path, size, weight):
    f = ImageFont.truetype(path, size)
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


W, H = 1280, 640
S = 2  # supersample
img = Image.new("RGB", (W * S, H * S), SLATE)
d = ImageDraw.Draw(img)

# subtle vertical gradient
for y in range(H * S):
    t = y / (H * S)
    c = tuple(round(SLATE[i] + (SLATE2[i] - SLATE[i]) * t) for i in range(3))
    d.line([(0, y), (W * S, y)], fill=c)

# Exa mark with a soft teal glow behind it.
cx, cy, r = 300 * S, 320 * S, 150 * S
glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([cx - r * 1.2, cy - r * 1.2, cx + r * 1.2, cy + r * 1.2], fill=(*TEAL, 70))
glow = glow.filter(ImageFilter.GaussianBlur(70 * S))
img.paste(glow, (0, 0), glow)
mark = Image.open(os.path.join(OUT, "exa-logo-dark.png")).convert("RGBA").resize((2 * r, 2 * r), Image.LANCZOS)
img.paste(mark, (cx - r, cy - r), mark)
d = ImageDraw.Draw(img)
x0 = 540 * S
d.text((x0, 168 * S), "SHAPING INNOVATION · FORGING THE FUTURE",
       font=font(SORA, 15 * S, 600), fill=TEAL)
d.text((x0 - 4 * S, 200 * S), "Exa", font=font(SORA, 120 * S, 700), fill=CREAM)
d.text((x0, 345 * S), "the Executive Assistant", font=font(SORA, 40 * S, 600), fill=ORANGE_LIFT)
d.text((x0, 412 * S), "An open-source AI assistant that lives on your\nAndroid phone — local-first, approval-gated.",
       font=font(MANROPE, 24 * S, 500), fill=GREY, spacing=10 * S)

img = img.resize((W, H), Image.LANCZOS)
small = fit_width(dark, 250)
img.paste(small, (W - small.width - 48, H - small.height - 40), small)
d = ImageDraw.Draw(img)
d.text((48, H - 62), "github.com/brightforge-tech  ·  AGPL-3.0", font=font(MANROPE, 18, 500), fill=(110, 122, 128))
img.save(os.path.join(OUT, "exa-banner.png"), optimize=True)
print("ok", os.listdir(OUT))
