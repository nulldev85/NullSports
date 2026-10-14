#!/usr/bin/env python3
"""Generate Lineup's icon for iPhone and Apple TV.

Two play triangles, both aimed forward: a large one in white and a small one
in the app's broadcast red, sharing one line along their backs, with rounded
corners. They sit on the app's own greys -- the ground lit a step lighter at
the top, as its cards are -- and are drawn as geometry at every size rather
than scaled from a picture.

On Apple TV the two triangles keep their own layers, so they part a little as
the icon tilts under focus; the Top Shelf matches. The iPhone's dark and
tinted icons keep the mark on the system's own ground.

Run from anywhere:

    python3 BuildAssets/generate-icons.py
"""

import math
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
TV = ROOT / "Lineup/Assets.xcassets/Lineup App Icon & Top Shelf Image.brandassets"
PHONE = ROOT / "iPhone/Assets.xcassets/LineupAppIcon.appiconset"

# The app's palette: its ground and its cards, and the accent it opens in.
GROUND_TOP = (0x2C, 0x2C, 0x2E)
GROUND_BOTTOM = (0x1C, 0x1C, 0x1E)
WHITE = (255, 255, 255)
RED = (0xFF, 0x33, 0x47)
TINT_GREY = (0xB4, 0xB4, 0xB8)
SS = 4  # supersampling

# The mark as it was drawn on a 1024 canvas -- two right triangles on one
# diagonal -- turned an eighth of a turn so their right angles aim forward.
BIG = [(250, 250), (770, 250), (770, 770)]
SMALL = [(250, 545), (478, 545), (478, 770)]
BIG_RADIUS = 30
SMALL_RADIUS = 12


def _rotate(points, angle, center):
    cx, cy = center
    c, s = math.cos(angle), math.sin(angle)
    return [(cx + (x - cx) * c - (y - cy) * s, cy + (x - cx) * s + (y - cy) * c) for x, y in points]


def _mark():
    """Both triangles, aimed forward, in a unit box: the larger side of their
    bounds is 1, and their optical centre is at the origin."""
    center = (510, 510)
    # Clockwise on screen by 45 degrees: the right angle at the top-right
    # corner comes round to point straight ahead.
    angle = math.radians(45)
    big = _rotate(BIG, angle, center)
    small = _rotate(SMALL, angle, center)
    xs = [x for x, _ in big + small]
    ys = [y for _, y in big + small]
    width, height = max(xs) - min(xs), max(ys) - min(ys)
    side = max(width, height)
    # A play mark looks left of centre when its box is centred, because its
    # weight sits at its back. Halfway between the box's centre and the
    # weight's is where it looks centred.
    box_x = (max(xs) + min(xs)) / 2
    weight_x = sum(x for x, _ in big) / 3
    origin = ((box_x + weight_x) / 2, (max(ys) + min(ys)) / 2)

    def unit(points):
        return [((x - origin[0]) / side, (y - origin[1]) / side) for x, y in points]

    return unit(big), unit(small), BIG_RADIUS / side, SMALL_RADIUS / side


BIG_UNIT, SMALL_UNIT, BIG_R, SMALL_R = _mark()


def _rounded_triangle(draw, points, radius, fill):
    """A triangle with round corners: the triangle drawn smaller by the
    radius, then widened by it again with a round pen."""
    (ax, ay), (bx, by), (cx, cy) = points
    a = math.dist((bx, by), (cx, cy))
    b = math.dist((ax, ay), (cx, cy))
    c = math.dist((ax, ay), (bx, by))
    perimeter = a + b + c
    ix = (a * ax + b * bx + c * cx) / perimeter
    iy = (a * ay + b * by + c * cy) / perimeter
    s = perimeter / 2
    area = math.sqrt(max(s * (s - a) * (s - b) * (s - c), 0))
    inradius = area / s
    k = max(0.0, 1 - radius / inradius)
    inner = [(ix + (x - ix) * k, iy + (y - iy) * k) for x, y in points]
    draw.polygon(inner, fill=fill)
    for i in range(3):
        p, q = inner[i], inner[(i + 1) % 3]
        draw.line([p, q], fill=fill, width=max(1, round(radius * 2)))
    for x, y in inner:
        draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=fill)


def _ground(size):
    width, height = size
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / max(height - 1, 1)
        colour = tuple(round(GROUND_TOP[i] + (GROUND_BOTTOM[i] - GROUND_TOP[i]) * t) for i in range(3))
        draw.line([(0, y), (width, y)], fill=colour)
    return image


def _layer(size, mark_size, parts):
    """`parts` is a list of (which, colour): which triangle, and in what."""
    width, height = size
    canvas = Image.new("RGBA", (width * SS, height * SS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    scale = mark_size * SS
    centre = (width * SS / 2, height * SS / 2)
    for which, colour in parts:
        unit, radius = (BIG_UNIT, BIG_R) if which == "big" else (SMALL_UNIT, SMALL_R)
        points = [(centre[0] + x * scale, centre[1] + y * scale) for x, y in unit]
        _rounded_triangle(draw, points, radius * scale, (*colour, 255))
    return canvas.resize(size, Image.Resampling.LANCZOS)


def _on_ground(size, mark_size, parts):
    image = _ground(size).convert("RGBA")
    image.alpha_composite(_layer(size, mark_size, parts))
    return image.convert("RGB")


def save(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    print(f"{image.width}x{image.height}  {path.relative_to(ROOT)}")


BOTH = [("big", WHITE), ("small", RED)]


def main():
    # iPhone: the mark at about half the icon's width, as it was.
    save(_on_ground((1024, 1024), 560, BOTH), PHONE / "LineupAppIcon.png")
    save(_layer((1024, 1024), 560, BOTH), PHONE / "LineupAppIcon-Dark.png")
    save(_layer((1024, 1024), 560, [("big", WHITE), ("small", TINT_GREY)]), PHONE / "LineupAppIcon-Tinted.png")
    save(_on_ground((1600, 960), 560, BOTH), ROOT / "BuildAssets/LineupMark.png")

    # Apple TV: ground, then the white triangle, then the red one in front.
    for stack, size, suffix in [
        ("App Icon - Small.imagestack", (400, 240), ""),
        ("App Icon - Small.imagestack", (800, 480), "@2x"),
        ("App Icon - Large.imagestack", (1280, 768), ""),
    ]:
        base = TV / stack
        mark = size[1] * 0.56
        save(_ground(size), base / "Background.imagestacklayer/Content.imageset" / f"Background{suffix}.png")
        save(_layer(size, mark, [("big", WHITE)]),
             base / "Middle.imagestacklayer/Content.imageset" / f"Middle{suffix}.png")
        save(_layer(size, mark, [("small", RED)]),
             base / "Foreground.imagestacklayer/Content.imageset" / f"Foreground{suffix}.png")

    for folder, size, suffix in [
        ("Top Shelf Image.imageset", (1920, 720), ""),
        ("Top Shelf Image.imageset", (3840, 1440), "@2x"),
        ("Top Shelf Image Wide.imageset", (2320, 720), ""),
        ("Top Shelf Image Wide.imageset", (4640, 1440), "@2x"),
    ]:
        name = folder.split(".")[0].replace(" ", "")
        save(_on_ground(size, size[1] * 0.40, BOTH), TV / folder / f"{name}{suffix}.png")


if __name__ == "__main__":
    main()
