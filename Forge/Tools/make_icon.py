#!/usr/bin/env python3
"""Renders Forge's app icon (1024×1024, no transparency) with Pillow.

A calm, modern mark: a barbell inside a progress ring (the timers), in the
app's mint and mist on deep ink with a soft glow.
"""
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersample, then downscale for smooth edges
OUT = Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

INK_TOP = (22, 33, 31)
INK_BOTTOM = (9, 12, 14)
MINT = (125, 211, 186)
MIST = (147, 184, 230)
BONE = (231, 236, 234)


def diagonal_gradient(size, start, end):
    w, h = size
    y, x = np.mgrid[0:h, 0:w]
    t = (x / (w - 1) * 0.35 + y / (h - 1) * 0.65)[..., None]
    arr = np.array(start) * (1 - t) + np.array(end) * t
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def ring_gradient(size, center, a, b):
    """Colors that sweep from `a` to `b` around the center (for the arc)."""
    w, h = size
    y, x = np.mgrid[0:h, 0:w]
    angle = (np.degrees(np.arctan2(y - center[1], x - center[0])) + 90) % 360 / 360
    t = angle[..., None]
    arr = np.array(a) * (1 - t) + np.array(b) * t
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def main():
    base = diagonal_gradient((S, S), INK_TOP, INK_BOTTOM)
    c = (S / 2, S / 2)

    # Soft mint glow behind the mark.
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((S * 0.2, S * 0.16, S * 0.8, S * 0.76), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.13))
    base = Image.composite(Image.new("RGB", (S, S), MINT), base, glow.point(lambda v: int(v * 0.20)))

    # Progress ring: a 300° arc with rounded ends, mint sweeping to mist.
    radius = S * 0.305
    width = S * 0.052
    start, sweep = -90 + 38, 300
    arc = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(arc)
    box = (c[0] - radius, c[1] - radius, c[0] + radius, c[1] + radius)
    d.arc(box, start=start, end=start + sweep, fill=255, width=int(width))
    for angle in (start, start + sweep):
        r = math.radians(angle)
        px = c[0] + (radius - width / 2) * math.cos(r)
        py = c[1] + (radius - width / 2) * math.sin(r)
        d.ellipse((px - width / 2, py - width / 2, px + width / 2, py + width / 2), fill=255)
    base = Image.composite(ring_gradient((S, S), c, MINT, MIST), base, arc)

    # Barbell: bar, collars and two plates per side.
    mark = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mark)
    def rect(cx, cy, w, h, r):
        d.rounded_rectangle((cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), radius=r, fill=255)
    rect(c[0], c[1], S * 0.40, S * 0.030, S * 0.015)
    for side in (-1, 1):
        rect(c[0] + side * S * 0.105, c[1], S * 0.052, S * 0.235, S * 0.022)
        rect(c[0] + side * S * 0.160, c[1], S * 0.042, S * 0.170, S * 0.018)
        rect(c[0] + side * S * 0.205, c[1], S * 0.022, S * 0.060, S * 0.010)
    shadow = mark.filter(ImageFilter.GaussianBlur(S * 0.018)).point(lambda v: int(v * 0.45))
    offset = Image.new("L", (S, S), 0)
    offset.paste(shadow, (0, int(S * 0.014)))
    base = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), base, offset)
    base = Image.composite(Image.new("RGB", (S, S), BONE), base, mark)

    base.resize((1024, 1024), Image.LANCZOS).save(OUT)
    print(OUT)


if __name__ == "__main__":
    main()
