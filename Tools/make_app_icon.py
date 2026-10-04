#!/usr/bin/env python3
"""Draws Lineup's app icon and writes every size the two targets ask for.

The mark is three blocks: one tall on the left, two stacked to its right --
a lineup, and a guide's own geometry, in the plainest possible terms.

Rebuilt from the supplied artwork as geometry rather than resampled from it.
Three rounded rectangles and two flat colours is all it is, and drawing it
means every size is exact rather than an interpolation of an 884-pixel
original -- and it means the blocks can be handed over without the field
behind them, which the television's layered icon and the tinted appearance
both need and a flattened picture cannot give.

Measured off the original, then regularised where the measurement was within
its own error: one corner radius rather than three within a pixel of each
other, one gutter, and the whole mark centred exactly rather than four pixels
shy of it.

    python3 Tools/make_app_icon.py
"""

from PIL import Image, ImageDraw
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FIELD = (7, 7, 7)           # the near-black the blocks sit on
INK = (253, 250, 243)       # warm off-white, not pure white

# The mark, in fractions of the icon's edge, measured off the artwork at its
# own 884-pixel tile and kept as exact ratios rather than rounded decimals.
#
# The parts agree with each other to the pixel: the tall block, a gutter and
# the bottom-right block span the same width as the whole mark; the top-right
# block, a gutter and the bottom-right block span the same height. So the
# outer box and one gutter give every edge, and nothing can drift out of
# alignment when a number is changed.
TILE = 884.0
GUTTER = 32 / TILE
RADIUS = 17.3 / TILE
TALL_W = 214 / TILE         # the left block
SMALL_H = 290 / TILE        # the top-right block
SMALL_W = 168 / TILE

WIDTH = 501 / TILE          # 214 + 32 + 255
HEIGHT = 578 / TILE         # 290 + 32 + 256
# Where the artwork puts it, not where the arithmetic would. It sits about a
# pixel and a half left and high of dead centre in its own tile, which is
# under two tenths of a percent -- far below anything the eye resolves, and
# not worth moving somebody's drawing for.
LEFT = 190 / TILE
TOP = 151 / TILE
RIGHT = LEFT + WIDTH
BOTTOM = TOP + HEIGHT

BLOCKS = (
    # left, top, right, bottom
    (LEFT, TOP, LEFT + TALL_W, BOTTOM),                       # tall, left
    (RIGHT - SMALL_W, TOP, RIGHT, TOP + SMALL_H),             # small, top right
    (LEFT + TALL_W + GUTTER, TOP + SMALL_H + GUTTER, RIGHT, BOTTOM),
)


def draw_mark(size, scale, centre, ink=INK):
    """The three blocks, on a transparent canvas, drawn around `centre`.

    `scale` is the icon's own edge length. The mark is proportional to it, so
    the television's wide icon keeps the phone's proportions instead of
    stretching them across the extra width.
    """
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    cx, cy = centre
    radius = RADIUS * scale
    for left, top, right, bottom in BLOCKS:
        box = [cx + (left - 0.5) * scale, cy + (top - 0.5) * scale,
               cx + (right - 0.5) * scale, cy + (bottom - 0.5) * scale]
        draw.rounded_rectangle(box, radius=radius, fill=(*ink, 255))
    return canvas


def square(edge, *, background=True, tinted=False):
    base = (Image.new("RGBA", (edge, edge), (*FIELD, 255)) if background
            else Image.new("RGBA", (edge, edge), (0, 0, 0, 0)))
    # Tinted carries no colour of its own: the system paints it, so the blocks
    # go down at full luminance and the field is left to whatever is behind.
    base.alpha_composite(draw_mark((edge, edge), edge, (edge / 2, edge / 2),
                                   ink=(255, 255, 255) if tinted else INK))
    return base


def widescreen(size, *, background=True, mark_scale=None, centre=None):
    w, h = size
    base = (Image.new("RGBA", size, (*FIELD, 255)) if background
            else Image.new("RGBA", size, (0, 0, 0, 0)))
    # Sized off the height, so the mark keeps the same share of a television
    # icon that it has of a phone's.
    scale = mark_scale or h
    base.alpha_composite(draw_mark(size, scale, centre or (w / 2, h / 2)))
    return base


def write(image, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path)
    print(f"  {os.path.relpath(path, ROOT)}  {image.size[0]}x{image.size[1]}")


def main():
    ios = os.path.join("iPhone", "Assets.xcassets", "LineupAppIcon.appiconset")
    print("iPhone")
    # Full bleed and square: iOS applies its own corner, and a picture that
    # brings its own gets rounded twice and sits inside a dark ring.
    write(square(1024).convert("RGB"), ios, "LineupAppIcon.png")
    write(square(1024, background=False), ios, "LineupAppIcon-Dark.png")
    write(square(1024, background=False, tinted=True), ios, "LineupAppIcon-Tinted.png")

    brand = os.path.join("Lineup", "Assets.xcassets",
                         "Lineup App Icon & Top Shelf Image.brandassets")
    print("tvOS")
    # Layered, and the split is the point: the television slides the
    # foreground against the background as the icon takes focus, so the
    # blocks travel over the field rather than the whole picture moving.
    for name, (w, h), suffix in [("App Icon - Large", (1280, 768), ""),
                                 ("App Icon - Small", (400, 240), ""),
                                 ("App Icon - Small", (800, 480), "@2x")]:
        stack = os.path.join(brand, f"{name}.imagestack")
        write(Image.new("RGB", (w, h), FIELD),
              stack, "Background.imagestacklayer", "Content.imageset",
              f"Background{suffix}.png")
        write(widescreen((w, h), background=False),
              stack, "Foreground.imagestacklayer", "Content.imageset",
              f"Foreground{suffix}.png")

    print("Top shelf")
    for name, (w, h), suffix in [("Top Shelf Image", (1920, 720), ""),
                                 ("Top Shelf Image", (3840, 1440), "@2x"),
                                 ("Top Shelf Image Wide", (2320, 720), ""),
                                 ("Top Shelf Image Wide", (4640, 1440), "@2x")]:
        image = widescreen((w, h), mark_scale=h * 0.92, centre=(w * 0.24, h / 2))
        write(image.convert("RGB"), brand, f"{name}.imageset",
              f"{name.replace(' ', '')}{suffix}.png")


if __name__ == "__main__":
    main()
