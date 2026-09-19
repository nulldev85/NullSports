#!/usr/bin/env python3
"""Draws Lineup's app icon and writes every size the two targets ask for.

The mark is an equalizer: five bars standing on a baseline, the tallest one
live. It says signal rather than list -- something on air, with a peak -- and
it is a shape nobody mistakes for a menu at any size.

On why it looks the way it does, since most of these are decisions against
something easier:

  No outer glow. A coloured blur behind a shape is the oldest shortcut in
  icon design and it reads as one. The peak earns its prominence by being
  the tallest thing and the only coloured thing, which is enough.

  The bars are lit from above and sit on a contact shadow. That is the whole
  difference between objects on a field and flat swatches on a background,
  and it is the only depth in the drawing -- one light, one direction, no
  highlights anywhere else pretending to a second source.

  The bars that are not the peak are one colour, not several. An earlier
  version had them catching light from the red one, which is a physical
  conceit in a drawing with no other physics in it. They are a cool slate
  with enough luminance to be a deliberate part of the mark rather than
  something switched off.

  The field has chroma. A neutral dark grey is what an icon looks like when
  nobody chose the background.

    python3 Tools/make_app_icon.py
"""

from PIL import Image, ImageDraw, ImageFilter
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Signal's palette, warmed and deepened for a mark that has to hold at forty
# points. An icon cannot change with the theme, so it commits.
FIELD = [(0.0, (22, 35, 58)), (0.55, (13, 21, 36)), (1.0, (7, 11, 18))]
# Lit from above: each bar's own face, brightest at the cap.
SLATE = [(0.0, (88, 104, 129)), (0.10, (74, 89, 113)), (1.0, (44, 55, 74))]
LIVE = [(0.0, (255, 114, 132)), (0.10, (250, 82, 104)), (1.0, (214, 26, 58))]

# One grid, at 1024. Every other size is this drawn larger or smaller, never
# re-laid-out, so the proportions cannot drift between platforms.
UNIT = 1024.0
BAR_W = 132 / UNIT
BAR_GAP = 42 / UNIT
BASELINE = 842 / UNIT
TALLEST = 660 / UNIT

# The levels. Deliberately not a staircase: bars that climb evenly read as
# signal strength, which is a different idiom and a much more generic one.
# Uneven around a peak, the way a meter is, with the peak at the optical
# centre so the one thing worth looking at is where the eye lands.
LEVELS = (0.46, 0.79, 1.00, 0.55, 0.70)
LIT = 2


def ramp(height, stops):
    """A vertical gradient from (position, colour) stops."""
    column = Image.new("RGB", (1, height))
    pixels = column.load()
    for y in range(height):
        t = y / max(1, height - 1)
        lower = stops[0]
        upper = stops[-1]
        for index in range(len(stops) - 1):
            if stops[index][0] <= t <= stops[index + 1][0]:
                lower, upper = stops[index], stops[index + 1]
                break
        span = max(1e-6, upper[0] - lower[0])
        k = (t - lower[0]) / span
        pixels[0, y] = tuple(round(a + (b - a) * k)
                             for a, b in zip(lower[1], upper[1]))
    return column


def wash(size, stops):
    return ramp(size[1], stops).resize(size, Image.BILINEAR)


def pill_mask(size, boxes):
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    for x, y, w, h in boxes:
        draw.rounded_rectangle([x - w / 2, y - h / 2, x + w / 2, y + h / 2],
                               radius=w / 2, fill=255)
    return mask


def geometry(scale, centre):
    """Where every bar stands, in pixels, for a mark of this size."""
    cx, cy = centre
    bar_w = BAR_W * scale
    pitch = (BAR_W + BAR_GAP) * scale
    span = len(LEVELS) * bar_w + (len(LEVELS) - 1) * BAR_GAP * scale
    left = cx - span / 2 + bar_w / 2
    base = cy + (BASELINE - 0.5) * scale
    boxes = []
    for index, level in enumerate(LEVELS):
        h = TALLEST * scale * level
        boxes.append((left + index * pitch, base - h / 2, bar_w, h))
    return boxes


def draw_mark(size, scale, centre, *, lift, tinted=False):
    """The bars, on a transparent canvas.

    `lift` adds the contact shadow. It is left off where the system composites
    the art over a backdrop of its own choosing and a shadow would be a smear
    against an unknown colour.
    """
    boxes = geometry(scale, centre)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))

    if tinted:
        # One channel: the system paints this, so all it may carry is how
        # light each part is. The peak stays the brightest thing.
        draw = ImageDraw.Draw(canvas)
        for index, (x, y, w, h) in enumerate(boxes):
            value = 255 if index == LIT else 122
            draw.rounded_rectangle([x - w / 2, y - h / 2, x + w / 2, y + h / 2],
                                   radius=w / 2, fill=(value, value, value, 255))
        return canvas

    if lift:
        # Tight, dark and downward. A contact shadow, not a halo: it says the
        # bars are standing on the field rather than floating over it.
        shadow = Image.new("RGBA", size, (0, 0, 0, 0))
        offset = [(x, y + scale * 0.014, w, h) for x, y, w, h in boxes]
        shadow.putalpha(pill_mask(size, offset).point(lambda v: v * 0.38))
        shadow = Image.composite(Image.new("RGBA", size, (0, 0, 0, 255)),
                                 Image.new("RGBA", size, (0, 0, 0, 0)),
                                 shadow.getchannel("A"))
        shadow = shadow.filter(ImageFilter.GaussianBlur(radius=scale * 0.022))
        canvas.alpha_composite(shadow)

    # Each bar is painted with its own gradient rather than a slab of colour,
    # so the cap catches the light and the foot falls away.
    for index, box in enumerate(boxes):
        x, y, w, h = box
        stops = LIVE if index == LIT else SLATE
        face = wash(size, stops).convert("RGBA")
        # The ramp is measured over the bar, not the canvas, so a short bar
        # gets the whole fall of light rather than a slice of it.
        band = ramp(max(2, round(h)), stops).resize((size[0], max(2, round(h))),
                                                    Image.BILINEAR)
        face = Image.new("RGBA", size, (0, 0, 0, 0))
        face.paste(band.convert("RGBA"), (0, round(y - h / 2)))
        face.putalpha(pill_mask(size, [box]))
        canvas.alpha_composite(face)
    return canvas


def square(edge, *, background=True, tinted=False):
    if background and not tinted:
        base = wash((edge, edge), FIELD).convert("RGBA")
    else:
        base = Image.new("RGBA", (edge, edge), (0, 0, 0, 0))
    base.alpha_composite(draw_mark((edge, edge), edge, (edge / 2, edge / 2),
                                   lift=background and not tinted, tinted=tinted))
    return base


def widescreen(size, *, background=True, mark_scale=None, centre=None):
    w, h = size
    base = (wash(size, FIELD).convert("RGBA") if background
            else Image.new("RGBA", size, (0, 0, 0, 0)))
    # Sized off the height: the mark is taller than it is wide, so height is
    # what fills a frame. Driving it off the width would run the bars off the
    # top and bottom of a television icon.
    scale = mark_scale or h * 1.04
    base.alpha_composite(draw_mark(size, scale, centre or (w / 2, h / 2),
                                   lift=background))
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
    # foreground against the background as the icon takes focus, so the bars
    # travel over the field rather than the whole picture moving as one.
    for name, (w, h), suffix in [("App Icon - Large", (1280, 768), ""),
                                 ("App Icon - Small", (400, 240), ""),
                                 ("App Icon - Small", (800, 480), "@2x")]:
        stack = os.path.join(brand, f"{name}.imagestack")
        field = wash((w, h), FIELD).convert("RGB")
        write(field, stack, "Background.imagestacklayer", "Content.imageset",
              f"Background{suffix}.png")
        write(widescreen((w, h), background=False),
              stack, "Foreground.imagestacklayer", "Content.imageset",
              f"Foreground{suffix}.png")

    print("Top shelf")
    for name, (w, h), suffix in [("Top Shelf Image", (1920, 720), ""),
                                 ("Top Shelf Image", (3840, 1440), "@2x"),
                                 ("Top Shelf Image Wide", (2320, 720), ""),
                                 ("Top Shelf Image Wide", (4640, 1440), "@2x")]:
        image = widescreen((w, h), mark_scale=h * 0.9, centre=(w * 0.24, h / 2))
        write(image.convert("RGB"), brand, f"{name}.imageset",
              f"{name.replace(' ', '')}{suffix}.png")


if __name__ == "__main__":
    main()
