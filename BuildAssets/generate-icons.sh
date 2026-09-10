#!/bin/bash
set -euo pipefail

assets='Lineup/Assets.xcassets/App Icon & Top Shelf Image.brandassets'
source='BuildAssets/LineupMark.png'
background=$(mktemp -t lineup-icon)
trap 'rm -f "$background"' EXIT
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY+Dk4vwPAAFYARw5ahBmAAAAAElFTkSuQmCC' | base64 --decode > "$background"

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
