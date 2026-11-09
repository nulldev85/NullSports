# Lineup's approved three-bar icon

The user approved this minimal red three-bar mark on 2026-11-08.

- `icon-color.png` is the exact approved opaque 1024px export. The normal and dark iOS catalog images are byte-identical copies.
- `icon-tinted.png` is the monochrome appearance derivative; packaging normalizes the final tinted PNG to equal RGB channels.
- `brand-mark.png` is the transparent red mark used in iOS welcome branding and tvOS icon/top-shelf layers.

Original artwork and both appearance derivatives were produced with the built-in image_gen tool. No creative changes are made by packaging: `BuildAssets/package-lineup-icon.ps1` only copies, uniformly resizes and composites the masters into the existing catalog dimensions. Apple supplies the outer icon mask. The app's icon-catalog names and bundle identifiers are unchanged.

Regenerate with `python BuildAssets/generate-icons.py` on Windows. Committed PNGs are used directly by CI.

## Original design prompt

The original generation requested a minimal, sleek, professional abstract symbol inspired by aligned programming, a lineup and forward movement; two or three geometric strokes, red `#FF3347` on charcoal `#1C1C1E`, flat artwork, balanced negative space, and no letters, sports pictograms, 3D effects or outer icon frame.

## Derivative prompts

The complete edit prompts are recorded in `derivative-prompts.md`.
