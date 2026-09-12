#!/usr/bin/env python3
"""Draws the Lineup app icon and writes every size the asset catalogs want.

The mark is a guide: three stacked lanes with a vertical now-line crossing
them, and the part of each lane the line has already passed is lit. That is
what the app's own guide does, and it is what keeps the shape from reading as
a hamburger menu with a pin stuck in it, which is what the old one read as.

Everything is drawn from numbers here rather than resampled from a source
bitmap, so a size can be added without finding the original artwork, and no
step needs macOS. Run from the repository root:

    python3 BuildAssets/generate-icons.py
"""

from PIL import Image, ImageDraw, ImageFilter
import os

SS = 4  # supersample factor; every edge below is drawn big and shrunk down

GROUND_TOP = (0x12, 0x17, 0x22)
GROUND_BOTTOM = (0x04, 0x06, 0x0A)
LANE_AHEAD = (0x2F, 0x37, 0x47)
LANE_ELAPSED = (0x5E, 0x6B, 0x80)
NOW_LINE = (0x22, 0xD3, 0xEE)

# Every measurement is a fraction of one unit, so the mark keeps its
# proportions on a square phone icon and a 5:3 television one alike.
LANE_SPAN = 0.660      # width of a lane
LANE_HEIGHT = 0.088
LANE_GAP = 0.070
NOW_WIDTH = 0.032
NOW_AT = 0.575         # how far along a lane the line sits: past the middle,
                       # because dead centre reads as a divider
NOW_OVERHANG = 0.035   # how far the line runs past the top and bottom lane


def ground(size):
    """The background: a cool near-black, lit very slightly from the top."""
    width, height = size
    image = Image.new("RGB", (1, height), GROUND_TOP)
    pixels = image.load()
    for y in range(height):
        t = y / max(1, height - 1)
        pixels[0, y] = tuple(
            round(a + (b - a) * t) for a, b in zip(GROUND_TOP, GROUND_BOTTOM)
        )
    return image.resize((width, height), Image.BILINEAR)


def geometry(size, unit):
    """Where each piece goes, in supersampled pixels."""
    width, height = (v * SS for v in size)
    u = unit * SS
    lane_w, lane_h, gap = LANE_SPAN * u, LANE_HEIGHT * u, LANE_GAP * u
    stack_h = lane_h * 3 + gap * 2
    left = (width - lane_w) / 2
    top = (height - stack_h) / 2
    lanes = [
        (left, top + i * (lane_h + gap), left + lane_w, top + i * (lane_h + gap) + lane_h)
        for i in range(3)
    ]
    now_x = left + lane_w * NOW_AT
    now_w = NOW_WIDTH * u
    overhang = NOW_OVERHANG * u
    now = (now_x - now_w / 2, top - overhang, now_x + now_w / 2, top + stack_h + overhang)
    return (int(width), int(height)), lanes, now, now_x


def lanes_layer(size, unit):
    """The three lanes, each lit up to the now-line and dim after it."""
    (w, h), lanes, _, now_x = geometry(size, unit)
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    shape = Image.new("L", (w, h), 0)
    shape_draw = ImageDraw.Draw(shape)
    for box in lanes:
        radius = (box[3] - box[1]) / 2
        draw.rounded_rectangle(box, radius=radius, fill=LANE_AHEAD + (255,))
        shape_draw.rounded_rectangle(box, radius=radius, fill=255)
    # The elapsed tone is painted through the lanes' own silhouette, so it
    # keeps their rounded left cap and stops dead on the line.
    elapsed = shape.copy()
    ImageDraw.Draw(elapsed).rectangle((now_x, 0, w, h), fill=0)
    layer.paste(Image.new("RGBA", (w, h), LANE_ELAPSED + (255,)), (0, 0), elapsed)
    return layer


def now_layer(size, unit):
    """The now-line, with the glow it throws onto whatever sits behind it."""
    (w, h), _, now, _ = geometry(size, unit)
    radius = (now[2] - now[0]) / 2
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle(now, radius=radius, fill=NOW_LINE + (120,))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=11 * SS * unit / 1024))
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    layer.alpha_composite(glow)
    ImageDraw.Draw(layer).rounded_rectangle(now, radius=radius, fill=NOW_LINE + (255,))
    return layer


def down(layer, size):
    return layer.resize(size, Image.LANCZOS)


def write(image, *path):
    target = os.path.join(*path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    image.save(target)
    print(f"{image.size[0]}x{image.size[1]}  {target}")


def flat(size, unit):
    """One opaque image with the whole mark on it, for the iOS catalog."""
    canvas = ground(size).convert("RGBA")
    canvas.alpha_composite(down(lanes_layer(size, unit), size))
    canvas.alpha_composite(down(now_layer(size, unit), size))
    return canvas.convert("RGB")


def top_shelf(size):
    """The banner across the top of the Apple TV home screen.

    tvOS shows this when Lineup is the selected app, at the full width of the
    television, and the App Store will not take a tvOS app without one. The
    mark is the same guide, laid out for a shape four times wider than it is
    tall: the same lanes and the same line, centred, at a size that carries
    across a room without crowding the edges a television may overscan.
    """
    _, height = size
    # The stack is 0.404 of a unit tall, so this puts it at a little under
    # half the banner's height -- enough to read across a room, far enough
    # from the edges that nothing is clipped by a television's overscan.
    unit = height * 1.16
    canvas = ground(size).convert("RGBA")
    canvas.alpha_composite(down(lanes_layer(size, unit), size))
    canvas.alpha_composite(down(now_layer(size, unit), size))
    return canvas.convert("RGB")


def main():
    phone = "iPhone/Assets.xcassets/AppIcon.appiconset"
    write(flat((1024, 1024), 1024), phone, "AppIcon.png")

    # The television icon is layered so tvOS can parallax it. The lanes belong
    # to the backing and the now-line to the front, so tilting the icon slides
    # the line across the guide instead of moving the whole mark as one slab.
    tv = "Lineup/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
    for folder, size, suffix in [
        ("Top Shelf Image.imageset", (1920, 720), ""),
        ("Top Shelf Image.imageset", (3840, 1440), "@2x"),
        ("Top Shelf Image Wide.imageset", (2320, 720), ""),
        ("Top Shelf Image Wide.imageset", (4640, 1440), "@2x"),
    ]:
        name = folder.split(".")[0].replace(" ", "")
        write(top_shelf(size), tv, folder, f"{name}{suffix}.png")

    for stack, size, suffix in [
        ("App Icon - Small.imagestack", (400, 240), ""),
        ("App Icon - Small.imagestack", (800, 480), "@2x"),
        ("App Icon - Large.imagestack", (1280, 768), ""),
    ]:
        unit = size[1] / 0.768  # the mark keeps the same share of the height
        backing = ground(size).convert("RGBA")
        backing.alpha_composite(down(lanes_layer(size, unit), size))
        write(backing.convert("RGB"), tv, stack,
              "Background.imagestacklayer/Content.imageset", f"Background{suffix}.png")
        write(down(now_layer(size, unit), size), tv, stack,
              "Foreground.imagestacklayer/Content.imageset", f"Foreground{suffix}.png")


if __name__ == "__main__":
    main()
