#!/usr/bin/env python3
"""Generate Lineup's play-in-grid icon for iPhone and Apple TV."""

from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
TV = ROOT / "Lineup/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
GROUND = (34, 29, 39)
MARK = (242, 237, 244)
SS = 3


def artwork(size, unit, transparent=False):
    width, height = size
    canvas = Image.new("RGBA", (width * SS, height * SS),
                       (0, 0, 0, 0) if transparent else (*GROUND, 255))
    draw = ImageDraw.Draw(canvas)
    center_x, center_y = width / 2, height / 2
    bar_width, bar_height, gap = unit * .60, unit * .085, unit * .145
    for offset in (-gap, 0, gap):
        box = (center_x - bar_width / 2, center_y + offset - bar_height / 2,
               center_x + bar_width / 2, center_y + offset + bar_height / 2)
        draw.rounded_rectangle(tuple(round(v * SS) for v in box),
                               radius=round(bar_height * SS / 2), fill=(*MARK, 255))
    # A single cutout across the three guide rows makes the play symbol.
    triangle = [(center_x - unit * .115, center_y - unit * .205),
                (center_x + unit * .225, center_y),
                (center_x - unit * .115, center_y + unit * .205)]
    draw.polygon([(round(x * SS), round(y * SS)) for x, y in triangle],
                 fill=(0, 0, 0, 0) if transparent else (*GROUND, 255))
    return canvas.resize(size, Image.Resampling.LANCZOS)


def save(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    print(f"{image.width}x{image.height}  {path.relative_to(ROOT)}")


def main():
    save(artwork((1024, 1024), 1024).convert("RGB"),
         ROOT / "iPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    save(artwork((1600, 960), 1250).convert("RGB"), ROOT / "BuildAssets/LineupMark.png")

    for folder, size, suffix in [
        ("Top Shelf Image.imageset", (1920, 720), ""),
        ("Top Shelf Image.imageset", (3840, 1440), "@2x"),
        ("Top Shelf Image Wide.imageset", (2320, 720), ""),
        ("Top Shelf Image Wide.imageset", (4640, 1440), "@2x"),
    ]:
        name = folder.split(".")[0].replace(" ", "")
        save(artwork(size, size[1] * 1.16).convert("RGB"), TV / folder / f"{name}{suffix}.png")

    for stack, size, suffix in [
        ("App Icon - Small.imagestack", (400, 240), ""),
        ("App Icon - Small.imagestack", (800, 480), "@2x"),
        ("App Icon - Large.imagestack", (1280, 768), ""),
    ]:
        base = TV / stack
        save(Image.new("RGB", size, GROUND),
             base / "Background.imagestacklayer/Content.imageset" / f"Background{suffix}.png")
        save(artwork(size, size[1] / .768, transparent=True),
             base / "Foreground.imagestacklayer/Content.imageset" / f"Foreground{suffix}.png")


if __name__ == "__main__":
    main()
