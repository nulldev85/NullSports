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
