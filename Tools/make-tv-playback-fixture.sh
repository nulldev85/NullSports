#!/bin/bash
set -euo pipefail
fixture_dir="Tests/tvOS/Fixtures"
mkdir -p "$fixture_dir"
cat > "$fixture_dir/playback.srt" <<'EOF'
1
00:00:00,000 --> 00:00:05,000
Lineup playback test

2
00:00:05,000 --> 00:00:11,900
Subtitles and resume work together
EOF
# Entirely generated color bars and tones, with two distinguishable audio
# tracks and timed text. No provider account or copyrighted footage is used.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000' \
  -i "$fixture_dir/playback.srt" -t 12 \
  -map 0:v -map 1:a -map 2:a -map 3:s \
  -c:v libx264 -profile:v baseline -pix_fmt yuv420p -g 24 -preset ultrafast \
  -c:a aac -b:a 64k -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title=English \
  -metadata:s:a:1 language=spa -metadata:s:a:1 title=Spanish \
  -metadata:s:s:0 language=eng "$fixture_dir/playback.mkv"
