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

- the evidence for each match, set on every pass;
- the loading flags, the error and the "validated" flags a provider refresh
  sets, every two minutes around a game still looking for its channel;
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

## Screens redraw only for what they show (both apps)

`SportsLibrary` and `MediaLibrary` were `ObservableObject`s: any change to
either redrew every screen that held it, the app's root included, whatever
the screen read. They are `@Observable` now, so a screen is redrawn only
when something it read changes. A score no longer redraws the Library, a
Library load no longer redraws the Sports tab, and neither redraws the
app's root.

What was observed before is observed now, and a little more:

- Every `@Published` property is an observed property.
- Other stored state stays unobserved (`@ObservationIgnored`) when it is
  internal: tasks, generations, digests, and caches filled while a screen
  reads them. Writing to an observed property while a screen draws would
  draw it again.
- State a screen shows but that never announced itself is observed now,
  where before a screen saw it only when something else happened to
  change: whether a refresh is under way (which feeds "syncing"), when the
  channels and guide were last fetched, the match identities playback
  checks against, a show's episodes, title details and counterparts on
  other servers.
- The provider's VOD list lives in `ProviderVOD`, which nothing observes.
  `providerCatalogRevision` moves each time it comes in, so the shelf
  picker and a provider episode's show cover are drawn again, as they were
  when the whole library announced every change.
- The schedule's confirmed leagues and the matching-done flag are still
  set on every refresh and every pass, changed or not. Under Observation
  that is exactly what redraws a game's row when its start time passes and
  nothing in the schedule moved.

Where something listened to every change it now listens to what it needs:
`gamesRevision` (game alerts, reminders), `streamsRevision` and favorites
(the channel picker), and `eventChannelsInputs`, everything the event
channel list is worked out from.

## The guide download (both apps)

An unchanged guide was already not parsed again, and its cache not
rewritten. It was still downloaded whole every refresh: about 100 MB for
the user's provider, and every two minutes around the start of a game
still looking for its channel. The guide is too big for the shared URL
cache, so `GuideValidators` keeps the server's `ETag` and `Last-Modified`
for the guide the app holds and asks whether it changed. A server that
keeps them answers 304 with nothing; one that doesn't sends the guide as
before. Validators are stored by a digest of the address, which carries
the account's password.

## Multiview when the phone runs hot (iPhone)

At a serious thermal state the muted picture is held to about 540p and
2.5 Mbps; the heard one never is. Only Apple's player can lower a stream,
and only one that offers more than one quality, so a single-quality
stream, or one on AetherEngine or VLC, plays as before. The playback log
records it when diagnostics are on.

## Device reports (iPhone)

Settings > Diagnostics > Device Reports shows Apple's MetricKit reports:
launch time, return from background, hangs, scroll hitches, CPU, data,
memory and storage written, one a day at most. The last fourteen are kept
on the phone. This is how the effect of these changes shows on a device.

## Faster builds (CI)

The iPhone workflow ran the simulator tests and then the release build,
about 24 and 6 minutes, one after the other. They now run side by side as
two jobs. The release build is uploaded as a candidate and published as
`Lineup-iPhone-unsigned-IPA` only when the tests pass, by a short job that
renames it, so a red run still publishes nothing. Every test still runs.

## Checked and left as they are

Already throttled or cheap, so not changed:

- Library playback progress is saved every 30 seconds, not every tick.
- The Guide's channel list is cached per filter and search.
- Expanded sports schedules cache for 20 seconds when a game is about to
  change and 5 minutes otherwise.
- The provider is downloaded again for an unmatched game only around its
  start (`ProviderRefreshPolicy`).
- Tennis is fetched by both the Sports tab and the live stats, but they are
  different requests (a day's schedule and the current scoreboard), two
  small ones every 30 seconds, and joining them would tie the Sports tab
  to the stats.

## Not measured here

There is no device in the build environment, so none of this is timed on
a phone. The figures above are from the user's earlier launch timing
report. The startup trace in Diagnostics still records each matching pass,
and should show far fewer of them during live games.
