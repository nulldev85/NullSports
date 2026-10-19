# Performance sweep

Work the app did over and over without anything on screen changing. No
feature is removed; each change keeps what the user sees and when.

## Channel matching on score changes (both apps)

Matching every game to every channel is the app's heaviest work. On the
user's iPhone it was measured at 20 to 28 seconds a pass for college games
alone, against 26,599 channels (see `ios-startup-matching.md`). The Sports
tab refreshes the schedule every 30 seconds, and every refresh that changed
anything ran a full pass. During live games a score always changes, so it
ran every 30 seconds for as long as any game was on.

A score, a clock, a match's sets and a race's running order can't change
which channel carries a game. `SportsLibrary.matchingInputs` is a game as
the matchers read it, without those. A refresh now rematches at once when
those inputs change: a game added, removed, started or finished, a new
broadcaster or start time, a college game delayed. When only scores moved,
it rematches at most every five minutes, which still rechecks kept matches
against the guide. Playback rechecks its channel at selection, as before.

A live game with no channel was retried on every refresh too, all day:
a slate always has some game no provider carries. It is still retried on
every refresh for its first half hour, when providers add a game's
channel and name it in the guide, and every five minutes after.

## Redraws from unchanged state (both apps)

Setting a published value redraws whatever watches it, even when the value
is the same. These are now set only when they change:

- the leagues the schedule has confirmed, set on every refresh;
- the evidence for each match and the matching-done flag, set on every pass;
- the iCloud sync status, set every 90 seconds by the app's root view,
  including in builds that can't sync at all.

## The schedule cache (both apps)

The last good schedule, shown on a cold start before the feed answers, was
kept in app preferences and rewritten on every score change. Preferences
are read whole at launch and written whole on every save. It is now a file
in the cache folder, `lineup-schedule.json`. The old copy is read once and
removed.

## Live stats in the background (iPhone)

The stats feed was asked every 5 to 10 seconds, and worked out every
second, while the app was in the background: in Picture in Picture or
playing sound alone, with nothing showing the stats. It now waits until
the app is back, then asks at once. What changed meanwhile is placed
between the two answers as always, so nothing shows early.

## Checked and left as they are

Already throttled or cheap, so not changed:

- Library playback progress is saved every 30 seconds, not every tick.
- The Guide's channel list is cached per filter and search.
- Expanded sports schedules cache for 20 seconds when a game is about to
  change and 5 minutes otherwise.
- The provider is downloaded again for an unmatched game only around its
  start (`ProviderRefreshPolicy`).

## Not measured here

There is no device in the build environment, so none of this is timed on
a phone. The figures above are from the user's earlier launch timing
report. The startup trace in Diagnostics still records each matching pass,
and should show far fewer of them during live games.
