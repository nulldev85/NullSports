#!/bin/bash
set -euo pipefail

assets='Lineup/Assets.xcassets/App Icon & Top Shelf Image.brandassets'
source='BuildAssets/LineupMark.png'
background=$(mktemp -t lineup-icon)
trap 'rm -f "$background"' EXIT
# A 1x1 pixel of the app's ground colour, scaled up to become each stack's
# backing layer. The committed layers already look like this; regenerating
# from a new mark should not quietly swap the backing to transparent.
# A 1x1 pixel of the app's ground colour, scaled up to become each stack's
# backing layer. The committed layers already look like this; regenerating
# from a new mark should not quietly swap the backing to transparent.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQklUHAADLAGe8FETtAAAAAElFTkSuQmCC' | base64 --decode > "$background"

make_icon() {
  local stack="$1" height="$2" width="$3" suffix="$4"
  local foreground="$assets/$stack/Foreground.imagestacklayer/Content.imageset/Foreground$suffix.png"
  local backing="$assets/$stack/Background.imagestacklayer/Content.imageset/Background$suffix.png"
  # Preserve the chosen 5:3 artwork's aspect ratio. Crop only rounding excess;
  # never squeeze the landscape NS mark into the old square foreground.
  sips --resampleHeight "$height" "$source" --out "$foreground" >/dev/null
  sips --cropToHeightWidth "$height" "$width" "$foreground" >/dev/null
  sips -z "$height" "$width" "$background" --out "$backing" >/dev/null
  for image in "$foreground" "$backing"; do
    test "$(sips -g pixelWidth "$image" | awk '/pixelWidth:/ { print $2 }')" = "$width"
    test "$(sips -g pixelHeight "$image" | awk '/pixelHeight:/ { print $2 }')" = "$height"
  done
}

make_icon 'App Icon - Small.imagestack' 240 400 ''
make_icon 'App Icon - Small.imagestack' 480 800 '@2x'
make_icon 'App Icon - Large.imagestack' 768 1280 ''
