#!/usr/bin/env python3
"""Draws Lineup's app icon and writes every size the two targets ask for.

The mark is an equalizer: five bars on a baseline, and the tallest one lit.
It says signal rather than list -- a set that is on air, with a peak -- which
is nearer what the app is than a stack of rows was. The lit bar is the tallest
as well as the only coloured one, so the shape carries it before the colour
does and the mark survives the tinted appearance, where the system takes the
colour away. Its neighbours catch a little of its light.

Kept as a script rather than exported once from a drawing tool, because the
icon needs eleven files across two platforms in three appearances, and a set
of PNGs nobody can regenerate is a set that drifts the first time one of them
is touched.

    python3 Tools/make_app_icon.py
"""

from PIL import Image, ImageDraw, ImageFilter
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The Signal palette, which is the one the icon speaks in. An icon cannot
# change with the theme, so it commits to the brighter of the two.
DEEP_TOP = (19, 32, 51)
DEEP_BOTTOM = (6, 9, 16)
LIVE_TOP = (251, 90, 114)
LIVE_BOTTOM = (232, 41, 63)
DIM_NEAR = (38, 52, 74)     # beside the lit row, catching its light
DIM_FAR = (28, 38, 53)
PAPER = (241, 245, 249)

# One grid, at 1024. Every other size is this drawn larger or smaller, never
# re-laid-out, so the proportions cannot drift between platforms.
UNIT = 1024.0
BAR_W = 116 / UNIT
BAR_GAP = 46 / UNIT         # edge to edge
BASELINE = 812 / UNIT       # where every bar stands
TALLEST = 580 / UNIT

# The levels. Deliberately not a staircase: bars that climb evenly read as
# signal strength, which is a different idiom and a much more generic one.
# The peak is the middle bar, which puts the one thing worth looking at at
# the optical centre, and the rest are uneven around it the way a meter is.
LEVELS = (0.50, 0.84, 1.00, 0.42, 0.68)
LIT = 2                     # which bar is live


def gradient(size, top, bottom):
    """A vertical wash. Flat colour at icon size reads as a sticker."""
    w, h = size
    image = Image.new("RGB", (1, h))
    pixels = image.load()
    for y in range(h):
        t = y / max(1, h - 1)
        pixels[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return image.resize((w, h), Image.BILINEAR)


def pill(draw, cx, cy, w, h, fill):
    draw.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2],
                           radius=h / 2, fill=fill)


def draw_mark(size, scale, centre, *, background, tinted=False):
    """The bars, on a transparent canvas, drawn around `centre`.

    `scale` is the icon's own edge length: the grid is proportional to it, so
    a wide television icon keeps the phone's proportions rather than stretching
    them across the extra width.
    """
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    cx, cy = centre
    bar_w = BAR_W * scale
    pitch = (BAR_W + BAR_GAP) * scale
    # The whole mark is centred on `centre`, so the field it occupies is
    # measured from the grid rather than from the canvas.
    span = len(LEVELS) * bar_w + (len(LEVELS) - 1) * BAR_GAP * scale
    left = cx - span / 2
    base = cy + (BASELINE - 0.5) * scale

    bars = []
    for index, level in enumerate(LEVELS):
        h = TALLEST * scale * level
        x = left + index * pitch + bar_w / 2
        y = base - h / 2
        if index == LIT:
            bars.append((x, y, h, None))
            continue
        near = abs(index - LIT) == 1
        colour = DIM_NEAR if near else DIM_FAR
        if tinted:
            # One channel only: the system paints this, so all it may carry
            # is how light each part is.
            colour = (150, 150, 150) if near else (110, 110, 110)
        elif not background:
            # No backdrop of its own to sit on, so the bars carry a little
            # more weight to hold against whatever is behind.
            colour = tuple(min(255, c + 26) for c in colour)
        bars.append((x, y, h, colour))

    # The glow goes down first and is blurred on its own layer, so the bars
    # stay crisp on top of it.
    if not tinted:
        halo = Image.new("RGBA", size, (0, 0, 0, 0))
        x, y, h, _ = bars[LIT]
        pill(ImageDraw.Draw(halo), x, y, bar_w, h, (*LIVE_BOTTOM, 150))
        halo = halo.filter(ImageFilter.GaussianBlur(radius=scale * 0.042))
        canvas.alpha_composite(halo)

    draw = ImageDraw.Draw(canvas)
    for x, y, h, colour in bars:
        if colour is not None:
            pill(draw, x, y, bar_w, h, (*colour, 255))

    # The lit bar last, and with its own wash -- brightest at the peak, so it
    # has a lit face rather than being a flat swatch.
    x, y, h, _ = bars[LIT]
    if tinted:
        pill(draw, x, y, bar_w, h, (255, 255, 255, 255))
    else:
        shape = Image.new("L", size, 0)
        pill(ImageDraw.Draw(shape), x, y, bar_w, h, 255)
        wash = gradient(size, LIVE_TOP, LIVE_BOTTOM).convert("RGBA")
        wash.putalpha(shape)
        canvas.alpha_composite(wash)
    return canvas


def square(edge, *, background=True, tinted=False):
    if background and not tinted:
        base = gradient((edge, edge), DEEP_TOP, DEEP_BOTTOM).convert("RGBA")
    else:
        base = Image.new("RGBA", (edge, edge), (0, 0, 0, 0))
    base.alpha_composite(draw_mark((edge, edge), edge, (edge / 2, edge / 2),
                                   background=background, tinted=tinted))
    return base


def wide(size, *, background=True, mark_scale=None, centre=None):
    """A television icon or a top shelf: the same mark, on a wider field."""
    w, h = size
    if background:
        base = gradient(size, DEEP_TOP, DEEP_BOTTOM).convert("RGBA")
    else:
        base = Image.new("RGBA", size, (0, 0, 0, 0))
    # Sized off the height. The mark is taller than it is wide now, so height
    # is what fills the frame; driving it off the width would run the bars off
    # the top and bottom of a television icon.
    scale = mark_scale or h * 1.04
    base.alpha_composite(draw_mark(size, scale, centre or (w / 2, h / 2),
                                   background=background))
    return base


def write(image, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path)
    print(f"  {os.path.relpath(path, ROOT)}  {image.size[0]}x{image.size[1]}")


def main():
    ios = os.path.join("iPhone", "Assets.xcassets", "AppIcon.appiconset")
    print("iPhone")
    write(square(1024).convert("RGB"), ios, "AppIcon.png")
    write(square(1024, background=False), ios, "AppIcon-Dark.png")
    write(square(1024, background=False, tinted=True), ios, "AppIcon-Tinted.png")

    brand = os.path.join("Lineup", "Assets.xcassets",
                         "App Icon & Top Shelf Image.brandassets")
    print("tvOS")
    # Layered, and the split is the point: the television slides the
    # foreground against the background as the icon is focused, so the rows
    # travel over the field rather than the whole picture sliding as one.
    for name, (w, h), suffix in [("App Icon - Large", (1280, 768), ""),
                                 ("App Icon - Small", (400, 240), ""),
                                 ("App Icon - Small", (800, 480), "@2x")]:
        stack = os.path.join(brand, f"{name}.imagestack")
        write(wide((w, h)).convert("RGB").resize((w, h)),
              stack, "Background.imagestacklayer", "Content.imageset",
              f"Background{suffix}.png")
        write(wide((w, h), background=False),
              stack, "Foreground.imagestacklayer", "Content.imageset",
              f"Foreground{suffix}.png")

    # Top shelf: the mark to the left, where a television's own title sits
    # over the right of the frame.
    print("Top shelf")
    for name, (w, h), suffix in [("Top Shelf Image", (1920, 720), ""),
                                 ("Top Shelf Image", (3840, 1440), "@2x"),
                                 ("Top Shelf Image Wide", (2320, 720), ""),
                                 ("Top Shelf Image Wide", (4640, 1440), "@2x")]:
        image = wide((w, h), mark_scale=h * 0.88, centre=(w * 0.24, h / 2))
        write(image.convert("RGB"), brand, f"{name}.imageset",
              f"{name.replace(' ', '')}{suffix}.png")


if __name__ == "__main__":
    main()
