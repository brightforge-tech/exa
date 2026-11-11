"""Exa the Executive Assistant - logo mark, generated from one geometry.

Usage: python tools/brand/exa_logo.py <repo root>   (needs Chrome; set CHROME=path to override)

Design (100 x 100 units, centre 50,50), echoing the BrightForge mark:
  - forge ring: a thick ink ring, an orange arc wrapping the outside from
    4 o'clock round the bottom to 10 o'clock, a teal arc inside the ring
    across the top - the same frame as the BrightForge logo.
  - the "E": three rounded bars on a spine (Exa / Executive). The bars echo
    the stacked base of the BrightForge bulb and read as a task list.
  - the spark: an orange dot beside the shorter middle bar - the AI at work.

Angles are SVG-style: 0 = 3 o'clock, increasing clockwise.
"""
import math
import os
import sys


TEAL = "#35B2BE"
ORANGE = "#C2551C"
INK = "#1E1C19"
CREAM = "#F2EFE9"
SLATE = "#0F1316"

RING = dict(r=36.0, w=12.0)                 # ink band (30..42)
OUTER = dict(r=45.6, w=7.6, a0=28, a1=212)  # orange band flush outside, through the bottom
INNER = dict(r=36.0, w=4.6, a0=226, a1=18)  # teal, embedded in the band, across the top
DISC_R = 30.5                               # inner face (light variant only)
BAR_W = 6.2
SPINE_X = 39.5
BARS = [(39.0, 60.5), (50.0, 53.0), (61.0, 60.5)]  # (y, x_end)
SPARK = dict(x=59.6, y=50.0, r=3.3)


def _pt(r, a):
    t = math.radians(a)
    return 50 + r * math.cos(t), 50 + r * math.sin(t)


def _sweep(a0, a1):
    return (a1 - a0) % 360


# ------------------------------------------------------------------ SVG --
def svg(ink, face=None, bg=None, size=512):
    def arc(spec, color, cap="round"):
        x0, y0 = _pt(spec["r"], spec["a0"])
        x1, y1 = _pt(spec["r"], spec["a1"])
        large = 1 if _sweep(spec["a0"], spec["a1"]) > 180 else 0
        return (f'<path d="M{x0:.2f} {y0:.2f} A{spec["r"]} {spec["r"]} 0 {large} 1 {x1:.2f} {y1:.2f}" '
                f'fill="none" stroke="{color}" stroke-width="{spec["w"]}" stroke-linecap="{cap}"/>')

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{'-14 -14 128 128' if bg else '0 0 100 100'}" width="{size}" height="{size}" role="img" aria-label="Exa the Executive Assistant">']
    if bg:
        parts.append(f'<rect x="-14" y="-14" width="128" height="128" rx="28" fill="{bg}"/>')
    if face:
        parts.append(f'<circle cx="50" cy="50" r="{DISC_R}" fill="{face}"/>')
    parts.append(arc(OUTER, ORANGE, cap="butt"))
    parts.append(f'<circle cx="50" cy="50" r="{RING["r"]}" fill="none" stroke="{ink}" stroke-width="{RING["w"]}"/>')
    parts.append(arc(INNER, TEAL))
    top, bottom = BARS[0][0], BARS[-1][0]
    parts.append(f'<path d="M{SPINE_X} {top} V{bottom}" stroke="{ink}" stroke-width="{BAR_W}" stroke-linecap="round"/>')
    for y, xe in BARS:
        parts.append(f'<path d="M{SPINE_X} {y} H{xe}" stroke="{ink}" stroke-width="{BAR_W}" stroke-linecap="round"/>')
    parts.append(f'<circle cx="{SPARK["x"]}" cy="{SPARK["y"]}" r="{SPARK["r"]}" fill="{ORANGE}"/>')
    parts.append("</svg>")
    return "\n".join(parts)


# ------------------------------------------------------------------ PNG --
CHROME = os.environ.get("CHROME", r"C:/Program Files/Google/Chrome/Application/chrome.exe")


def render(svg_text, size, out):
    """Rasterise an SVG with headless Chrome (transparent background)."""
    import subprocess
    import tempfile
    tmp = tempfile.mkdtemp()
    html = os.path.join(tmp, "x.html")
    body = svg_text.replace('width="512" height="512"', f'width="{size}" height="{size}"', 1)
    open(html, "w", encoding="utf-8").write(
        f"<html><body style='margin:0;background:transparent'>{body}</body></html>")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    f"--user-data-dir={tmp}/prof", "--default-background-color=00000000",
                    f"--window-size={size},{size}", f"--screenshot={out}",
                    "file:///" + html.replace(os.sep, "/")],
                   check=True, capture_output=True, timeout=60)


# ------------------------------------------------- Android vector drawable --
def android_foreground(ink):
    """Adaptive-icon foreground: the mark scaled into the 66dp safe zone."""
    scale = 33.0 / (OUTER["r"] + OUTER["w"] / 2)  # outer edge -> 33dp radius
    t = 54 - 50 * scale

    def arc(spec, color, cap="round"):
        x0, y0 = _pt(spec["r"], spec["a0"])
        x1, y1 = _pt(spec["r"], spec["a1"])
        large = 1 if _sweep(spec["a0"], spec["a1"]) > 180 else 0
        return (f'        <path android:pathData="M{x0:.2f},{y0:.2f} A{spec["r"]},{spec["r"]} 0 {large},1 {x1:.2f},{y1:.2f}"\n'
                f'            android:strokeColor="{color}" android:strokeWidth="{spec["w"]}" android:strokeLineCap="{cap}" />')

    r = RING["r"]
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<!-- Exa mark: BrightForge forge ring around an "E" with an AI spark.',
        '     Generated from the logo geometry; see .github/assets/exa-logo.svg. -->',
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
        '    android:width="108dp"', '    android:height="108dp"',
        '    android:viewportWidth="108"', '    android:viewportHeight="108">',
        f'    <group android:translateX="{t:.3f}" android:translateY="{t:.3f}"',
        f'        android:scaleX="{scale:.4f}" android:scaleY="{scale:.4f}">',
        arc(OUTER, ORANGE, cap="butt"),
        f'        <path android:pathData="M{50 - r},50 a{r},{r} 0 1,0 {2 * r},0 a{r},{r} 0 1,0 {-2 * r},0"\n'
        f'            android:strokeColor="{ink}" android:strokeWidth="{RING["w"]}" />',
        arc(INNER, TEAL),
        f'        <path android:pathData="M{SPINE_X},{BARS[0][0]} V{BARS[-1][0]}'
        + "".join(f' M{SPINE_X},{y} H{xe}' for y, xe in BARS) + '"\n'
        f'            android:strokeColor="{ink}" android:strokeWidth="{BAR_W}" android:strokeLineCap="round"\n'
        '            android:strokeLineJoin="round" />',
        f'        <path android:pathData="M{SPARK["x"] - SPARK["r"]},{SPARK["y"]} a{SPARK["r"]},{SPARK["r"]} 0 1,0 {2 * SPARK["r"]},0 a{SPARK["r"]},{SPARK["r"]} 0 1,0 {-2 * SPARK["r"]},0"\n'
        f'            android:fillColor="{ORANGE}" />',
        '    </group>',
        '</vector>',
    ]
    return "\n".join(lines) + "\n"


def android_monochrome():
    """Themed-icon (Android 13+) layer: same mark, one colour."""
    return android_foreground("#FFFFFFFF").replace(ORANGE, "#FFFFFFFF").replace(TEAL, "#FFFFFFFF")


if __name__ == "__main__":
    repo = sys.argv[1]
    assets = os.path.join(repo, ".github", "assets")
    res = os.path.join(repo, "exa_mobile", "android", "app", "src", "main", "res")
    os.makedirs(assets, exist_ok=True)

    open(os.path.join(assets, "exa-logo.svg"), "w").write(svg(INK, face="#FFFFFF"))
    open(os.path.join(assets, "exa-logo-dark.svg"), "w").write(svg(CREAM))
    open(os.path.join(assets, "exa-app-icon.svg"), "w").write(svg(CREAM, bg=SLATE))
    render(svg(INK, face="#FFFFFF"), 512, os.path.join(assets, "exa-logo.png"))
    render(svg(CREAM), 512, os.path.join(assets, "exa-logo-dark.png"))
    render(svg(CREAM, bg=SLATE), 512, os.path.join(assets, "exa-app-icon.png"))

    open(os.path.join(res, "drawable", "ic_launcher_foreground.xml"), "w", newline="\n").write(android_foreground(CREAM))
    open(os.path.join(res, "drawable", "ic_launcher_monochrome.xml"), "w", newline="\n").write(android_monochrome())
    # Legacy launcher PNGs (pre-API-26 launchers and some stores).
    for folder, px in [("mipmap-mdpi", 48), ("mipmap-hdpi", 72), ("mipmap-xhdpi", 96),
                       ("mipmap-xxhdpi", 144), ("mipmap-xxxhdpi", 192)]:
        path = os.path.join(res, folder, "ic_launcher.png")
        if os.path.exists(path):
            render(svg(CREAM, bg=SLATE), px, path)
    print("ok")
