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

The viewer's delay is one number: how many seconds the picture is behind
live, kept per channel.

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

On a tennis tournament with several matches on court, the viewer picks the
match on their screen first. Its plays are the ones synced to.

Polling: summaries every 10 seconds while live. Tennis scoreboards every 10
seconds, which matches ESPN's cache. Fight cards and races every 5. Anything
not live, once a minute.

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
