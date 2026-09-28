#!/usr/bin/env python3
"""Builds the app's bundled fonts from the variable fonts on Google Fonts.

Forge uses Manrope for text and Geist Mono for numbers and data. iOS looks
fonts up by PostScript name, so each weight is cut into its own static file
(Manrope-SemiBold.ttf → "Manrope-SemiBold").

Requires: pip install fonttools
Usage:    python3 Tools/make_fonts.py
Output:   App/Resources/Fonts/*.ttf plus each family's OFL license.
Both fonts are licensed under the SIL Open Font License 1.1.
"""
import io
import os
import urllib.parse
import urllib.request

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "Resources", "Fonts")
BASE = "https://raw.githubusercontent.com/google/fonts/main/ofl"

FAMILIES = [
    # (directory, variable file, family name, [(weight, style)])
    ("manrope", "Manrope[wght].ttf", "Manrope",
     [(400, "Regular"), (500, "Medium"), (600, "SemiBold"), (700, "Bold"), (800, "ExtraBold")]),
    ("geistmono", "GeistMono[wght].ttf", "Geist Mono",
     [(300, "Light"), (400, "Regular"), (500, "Medium"), (600, "SemiBold"), (700, "Bold")]),
]


def fetch(directory, name):
    url = f"{BASE}/{directory}/{urllib.parse.quote(name)}"
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def set_names(font, family, style):
    """Names each static cut as its own family member, so iOS registers
    every weight under a distinct PostScript name."""
    postscript = f"{family.replace(' ', '')}-{style}"
    ribbi = style in ("Regular", "Bold")
    table = font["name"]
    for record in list(table.names):
        if record.nameID in (1, 2, 3, 4, 6, 16, 17, 25):
            table.removeNames(nameID=record.nameID)
    legacy_family = family if ribbi else f"{family} {style}"
    legacy_style = style if ribbi else "Regular"
    for name_id, value in [
        (1, legacy_family),
        (2, legacy_style),
        (3, f"{postscript};Forge"),
        (4, f"{family} {style}"),
        (6, postscript),
        (16, family),
        (17, style),
    ]:
        table.setName(value, name_id, 3, 1, 0x409)
        table.setName(value, name_id, 1, 0, 0)
    return postscript


def main():
    os.makedirs(OUT, exist_ok=True)
    for directory, variable, family, cuts in FAMILIES:
        data = fetch(directory, variable)
        for weight, style in cuts:
            font = TTFont(io.BytesIO(data))
            static = instancer.instantiateVariableFont(font, {"wght": weight})
            postscript = set_names(static, family, style)
            os2 = static["OS/2"]
            os2.usWeightClass = weight
            bold = style == "Bold"
            # fsSelection: bit 5 = bold, bit 6 = regular; macStyle bit 0 = bold.
            os2.fsSelection = (os2.fsSelection & ~0b1100000) | (0b100000 if bold else 0b1000000)
            static["head"].macStyle = (static["head"].macStyle & ~1) | (1 if bold else 0)
            path = os.path.join(OUT, f"{postscript}.ttf")
            static.save(path)
            print(f"{os.path.getsize(path):>8}  {path}")
        license_name = f"OFL-{family.replace(' ', '')}.txt"
        with open(os.path.join(OUT, license_name), "wb") as handle:
            handle.write(fetch(directory, "OFL.txt"))
        print(f"          {license_name}")


if __name__ == "__main__":
    main()
