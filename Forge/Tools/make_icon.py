#!/usr/bin/env python3
"""Renders Forge's app icon (1024×1024, no transparency) with Pillow."""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersample, then downscale for smooth edges
OUT = Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(size, top, bottom):
    h = size[1]
    arr = np.zeros((h, size[0], 3), dtype=np.uint8)
    for y in range(h):
        arr[y, :, :] = lerp(top, bottom, y / (h - 1))
    return Image.fromarray(arr, "RGB")


def main():
    base = vertical_gradient((S, S), (30, 30, 36), (8, 8, 11))

    # Warm glow behind the mark.
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((S * 0.18, S * 0.20, S * 0.86, S * 0.88), fill=150)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.12))
    ember = Image.new("RGB", (S, S), (255, 96, 32))
    base = Image.composite(ember, base, glow.point(lambda v: int(v * 0.45)))

    # The mark: a bold, forward-leaning F whose top stroke is a loaded bar.
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    r = S * 0.035
    dx = -S * 0.035
    def box(x0, y0, x1, y1):
        return (x0 * S + dx, y0 * S, x1 * S + dx, y1 * S)
    stem = box(0.33, 0.27, 0.46, 0.79)
    top = box(0.33, 0.27, 0.66, 0.385)
    mid = box(0.33, 0.49, 0.60, 0.595)
    for rect in (stem, top, mid):
        d.rounded_rectangle(rect, radius=r, fill=255)
    # The top stroke becomes a loaded barbell: collar, two plates, sleeve.
    d.rounded_rectangle(box(0.64, 0.312, 0.84, 0.343), radius=S * 0.014, fill=255)
    d.rounded_rectangle(box(0.665, 0.205, 0.725, 0.45), radius=S * 0.022, fill=255)
    d.rounded_rectangle(box(0.738, 0.24, 0.782, 0.415), radius=S * 0.018, fill=255)

    # Lean it forward.
    shear = 0.16
    mask = mask.transform((S, S), Image.AFFINE, (1, shear, -shear * S * 0.5, 0, 1, 0), resample=Image.BICUBIC)

    fill = vertical_gradient((S, S), (255, 150, 72), (240, 58, 30))
    shadow = mask.filter(ImageFilter.GaussianBlur(S * 0.02)).point(lambda v: int(v * 0.55))
    offset = Image.new("L", (S, S), 0)
    offset.paste(shadow, (int(S * 0.012), int(S * 0.02)))
    base = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), base, offset)
    base = Image.composite(fill, base, mask)

    # A thin highlight along the top edges of the mark.
    highlight = mask.filter(ImageFilter.GaussianBlur(S * 0.004))
    inner = Image.new("L", (S, S), 0)
    inner.paste(mask, (0, int(S * 0.006)))
    edge = Image.fromarray(np.clip(np.asarray(highlight, dtype=np.int16) - np.asarray(inner, dtype=np.int16), 0, 255).astype(np.uint8))
    base = Image.composite(Image.new("RGB", (S, S), (255, 214, 170)), base, edge.point(lambda v: int(v * 0.7)))

    icon = base.resize((1024, 1024), Image.LANCZOS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUT, "PNG")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
