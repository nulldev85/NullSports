Tools/make-tv-playback-fixture.sh generates playback.mkv before XcodeGen runs.
It contains only synthetic video, sine-wave audio, and Lineup test captions.
With the ios argument it also creates longer MP4, MPEG-2 MKV, and raw TS clips.

Sports fixtures captured from ESPN's public scoreboards on 2026-10-16:
- soccer-schedule.json: soccer/eng.1/scoreboard?dates=20261017
- f1-weekend.json: racing/f1/scoreboard?dates=20261023-20261026
- f1-result.json: racing/f1/scoreboard?dates=20261011
- nascar-schedule.json: racing/nascar-premier/scoreboard?dates=20261015-20261019
Base URL: https://site.api.espn.com/apis/site/v2/sports/
Only fields consumed by Lineup are retained; odds, ticket links, and other
unrelated fields are removed. The F1 result fixture retains the race session
only. Source dates, IDs, status, driver order/flags and broadcasts are preserved.

Domestic cup fixtures captured from the same base on 2026-10-30:
- soccer-eng.league_cup.json: soccer/eng.league_cup/scoreboard?limit=1
- soccer-eng.fa.json: soccer/eng.fa/scoreboard?limit=1
- soccer-esp.copa_del_rey.json: soccer/esp.copa_del_rey/scoreboard?limit=1
- soccer-esp.super_cup.json: soccer/esp.super_cup/scoreboard?limit=1
These four captures retain the original ESPN JSON. Tests additionally construct
explicit replay/unknown-competition cases without altering the captures.

College basketball fixture captured from the same base on 2026-11-14:
- ncaab-scoreboard.json: basketball/mens-college-basketball/scoreboard?dates=20261114&groups=50&limit=400
Three games kept: a finished one with a ranked side (14 Gonzaga) and two
live ones. Links, statistics, leaders and line scores are removed.
