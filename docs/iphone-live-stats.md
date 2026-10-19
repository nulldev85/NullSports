# iPhone live stats

The stats panel beside or under the picture follows the game on screen and
holds everything it shows until the viewer's picture reaches it. A score,
a play or a result is never shown before the stream shows it.

## Where each sport's stats come from

All from ESPN's public site API (`site.api.espn.com`).

| Sport | Feed | What it has |
| --- | --- | --- |
| NFL, college football, NBA, NHL, MLB | `summary?event=` | Plays with the moment each happened, box score, leaders, win probability |
| Soccer | `soccer/{competition}/summary?event=` | Commentary (every shot, corner, card, sub) and key events with their moments, team totals, leaders |
| Tennis (ATP, WTA) | `tennis/{tour}/scoreboard` | Set-by-set games, who is serving, the day's draw |
| UFC | `mma/ufc/scoreboard?dates=` | Every fight's round, clock, winner and method, and the fight's logged moments (takedowns, knockdowns, round ends) |
| F1, NASCAR Cup | `racing/{series}/scoreboard?dates=` | The running order and lap |

Tennis, UFC and racing have no summary feed (it answers 400 or 404) and no
play-by-play, so those feeds are read as boards: how things stand at each
fetch. NFL RedZone has no stats, since it moves between games.

## Holding it back

The viewer's delay is how many seconds the picture is behind ESPN, kept per
channel and per kind of feed: plays, tennis, fight cards and races each have
their own. A play's moment is when it happened on the field; a board's is
when ESPN posted it, already some way behind the field, by a different way
for each sport. So one kind's delay never stands in for another's.

Unset, plays, fight cards and races are held a minute. Tennis is not held: a
game reaches ESPN only after its last point, and holding it a minute more
left scores minutes behind the picture. It shows the moment ESPN has it
until the viewer syncs.

- A play with a time of its own (ESPN's `wallclock`) shows once that time
  plus the delay has passed.
- A summary's box score stands for the latest play in the same fetch and
  shows with it.
- A board is held to the time the fetch came back.
- What changed between two boards (a game won, a takedown, a new leader) is
  worked out by comparing them, and placed between the two fetches: after
  the earlier one, by the later one. It shows no sooner than the later one.

## Syncing

The sync sheet shows the latest play in the stats and asks whether it is on
screen. "It Just Happened" sets the delay to how long ago it happened. For
a play worked out from two boards, that is reckoned from the earlier fetch,
the earliest it can have happened. So later changes come a few seconds
after the picture shows them, and never before.

"Already Saw It" on the latest play, with nothing later from ESPN, means the
stream is as far on as the feed: the delay goes to nothing, and everything
shows the moment ESPN has it. (It used to sync to that play, which held
everything after it by however long ago it had happened: minutes, if the
sheet was opened late.)

On a tennis tournament with several matches on court, the viewer picks the
match on their screen first. That match's games are what syncing uses.

## The Courts tab

Only the match on the viewer's screen is held. The other courts aren't on
it, so they show as ESPN has them, as soon as the panel opens, and update
with every fetch. The match on screen shows as the picture has it. Until
the picture reaches it, the row shows who is playing and no score. On a
tournament channel, until the viewer picks a match, any match that could be
on screen is held: one under way, or one the picture hasn't seen finish.

ESPN's tennis scoreboard has games and sets but no points, so a match moves
a game at a time. That is too little for a list of plays, so tennis has the
scoreboard and the Courts tab only. The games are still worked out behind
the scenes, and the sync sheet uses them.

## Freshness

Every request skips the phone's own cache. ESPN's cache keeps a copy for
up to ten seconds, and its `max-age` says how long this one has left, so a
change between two boards is placed after the earlier board's data could
have been taken, not after it arrived.

Polling: summaries every 10 seconds while live. Tennis scoreboards, fight
cards and races every 5: ESPN's copy is up to ten seconds old, so asking
twice as often takes each change from it sooner. Anything not live, once a
minute.
In the background (Picture in Picture, or sound alone) the feed isn't
asked at all. It is asked again the moment the app is back.

Measured on live ATP and WTA matches, ESPN posts each game on its own as it
ends, a few minutes apart as real games are. Who is serving lags: it comes
back for every match of a tour at once, a minute or two later, so it is
worked out from the games between.

## Code

- `iPhone/MobileGameStatsFeed.swift`: summary parsing, including soccer, and
  the timeline that holds everything back.
- `iPhone/MobileGameBoards.swift`: tennis, fight card and race boards, and
  the plays worked out from two of them.
- `iPhone/MobileGameStats.swift`: which feed a game uses, fetching, and
  holding the Sports tab's score with the stats.
- `iPhone/MobileGameStatsPanel.swift`, `iPhone/MobileGameBoardViews.swift`:
  the panel and the sync sheet.
- `Tests/MobileGameStatsChecks.swift`, `Tests/MobileGameBoardChecks.swift`:
  run in the iOS build's "Check shared sports logic" step.

## Auto Sync

With the stats open on a live game whose feed has timed plays (football,
basketball, hockey, baseball, soccer), the iPhone reads the broadcast's own
scoreboard and sets the delay itself. It is on by default and can be switched
off in the sync sheet; it runs only in the foreground, rests when the phone is
hot, and nothing leaves the device.

- **Frames.** AVPlayer and Aether's native routes through an
  `AVPlayerItemVideoOutput` on the playing item (attached while Auto Sync
  runs, removed when it stops); Aether's software route from its renderer's
  displayed frame; VLC through libvlc's own snapshot, written to a file and
  read back. Once a second until the delay settles, every four after.
- **Reading.** Vision's text recognition, digits as they are (no language
  correction). A game clock is minutes and seconds standing alone, not a time
  of day, not longer than the sport's longest period; a score is the number
  beside a side's code in the same line or the next one along.
- **Estimates.** A countdown clock (football, basketball) reaching a play's
  time, first seen then, gives one: seen minus happened, less the viewer's own
  pauses. Hockey's feed counts up within the period, so its plays are turned
  around. Soccer's clock never stops, so every running reading gives one from
  the nearest play; a clock held at 45:00 is ignored. A score changing on
  screen to one a play made gives one, timed from its first sighting and only
  once read twice.
- **Agreement.** The delay is the median of the largest group of estimates
  within 2.5 seconds of each other (three, or two for baseball), from the last
  ten minutes, ties to the longer. The ways an estimate goes wrong that are not
  random (a clock stopped on a play's time before the play) make it short, so
  football adds four seconds and the others one. A hand sync stands until the
  scoreboard differs by a second or more.
