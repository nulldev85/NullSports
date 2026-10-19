# iOS startup and quality selection

The user's iPhone 114 Launch Timing report identified CPU work, rather than a
slow guide download, as the main startup delay for this provider:

- 26,599 channels and 8,269 guide channels restored in 0.43 seconds.
- A cached rematch ran for 37.13 seconds before fresh provider requests started.
- Fresh channels took 1.01 seconds; the 99.9 MB guide download/parse took 5.32.
- Channel and guide changes each started an index build, taking about 16 seconds
  each. The first result was discarded after doing the full work.
- College matching repeatedly scored 20,752 candidates against 41–49 games,
  taking 20–28 seconds per pass. Further passes continued through 275 seconds.

These are observed device measurements, not a guaranteed future runtime.

## Changes

iOS starts its provider/schedule refresh after installing disk data and before
awaiting cached index/matching work. Disk reads cannot overwrite fresh responses.
The bootstrap does not start a second provider refresh if the early channel
request finishes while its guide is still running. Playback still requires fresh
channel/schedule/guide evidence under the existing readiness rules.

Replacing an iOS index cancels its old index and matching worker. Replacing
matching cancels its old worker, including preparation. Workers check cancellation
within their channel/game loops. New work starts immediately rather than waiting
for full stale passes in a serial queue. Generation/profile guards still reject
late results, and an old completion cannot retire a newer worker.

A conservative word index narrows team-game candidates before full scoring. Any
accepted team alias must contain its first whole normalized word in a channel
name or listing. The index retains channels containing ANY side's alias word;
it does not require both teams, preserving college's partial school/network
evidence. The original scorers decide every retained candidate. Network-only
fallback remains disabled. RedZone, racing, UFC and tennis retain their complete
pools. New/unknown alias queries fall back to the full pool.

Only words relevant to the current slate are retained, once per shared guide
channel. There is no persistent word set for every listing. Professional text
preparation reads referenced candidate guides rather than the entire provider
guide. All original raw guide data remains available in TV Guide.

Small league-classification facts persist with the existing channel index. They
are keyed by exact SHA-256 fingerprints of the ordered title/detail fields and
app build. Dates do not affect league classification; full fresh dates and
listings continue to drive matching and playback validation. Changed text,
removed listings, or a new build recompute the classification. Cache misses
compute the original league policy. There is no reduced league/team coverage.

The Channels/automatic quality discovery paths can reuse conservative candidate
hints only for the same index generation and event identity. Full strict event
validation still runs. College channels outside the ordinary automatic matching
pool remain eligible for discovery. Category-only vetoes run once per category
before expensive guide preparation. Complete Channels lists remain complete;
deadline-truncated discovery is still never cached as a complete result.

## Quality follow-up

The user also reported automatic playback regressing from 1080p to 720p for an
Ohio State game. A scheduling defect can produce that symptom: all channels'
TS variants are checked before HLS alternates, exhausting the deadline on 720p
TS even when the same channel's HLS is 1080p. The private feed itself has not been
probed here, so this is not proof of that provider's particular rendition layout.

iOS now prioritizes an unmeasured alternate when measured quality falls below
the channel hint, or direct TS is below 1080p. A selected HLS upgrade gets up to
two seconds for its playlist/media read within the same four-second overall
budget; ordinary URL probes retain the 1.25-second limit. Cached partial 720p
measurements do not prevent an unmeasured alternate being checked. Winning
quality and the exact playback URL remain measured; an FHD label cannot invent
1080p. Provider sockets still close before another probe opens. Discovery time,
remaining probe budget and measured selection now appear in Launch Timing.

## Validation

New iOS regressions compare every positive college/professional score against
the conservative index, including partial/delayed evidence, aliases, wrong
coverage, and shared HD/FHD guides. A 26,599-channel/49-game fixture checks guide
deduplication and candidate counts. Cache tests cover text/date changes, field
boundaries, serialization and app-version invalidation. Work tests await real
start/cancel callbacks and protect newer work from obsolete completion.

Quality regressions cover the constrained 720p-TS/1080p-HLS case, cached partial
results after relaunch, a playlist/media handshake exceeding the ordinary URL
budget, and a misleading FHD label with genuinely 720p media. Existing playback,
relevance, tracking, navigation and full simulator coverage remain enabled.
Apple SDK execution is pending CI; Swift/Xcode are unavailable on this Windows
workspace. The speed improvement on the user's actual provider needs a new
device timing report after installing the review build.

## Kept matches stay kept

A matching pass runs on every refresh that changes what matching reads, every
few minutes while a live game has no channel, and every five minutes when only
scores moved. Most of those passes keep every match they already have, and
each used to prepare every candidate channel's guide first.

A pass now reads a channel's guide the first time it needs it. A game whose
match is kept (its signature unchanged, the kept channel still verified against
the current guide, not in another language, not a tennis channel shared between
tournaments) reads that one channel. A game looked for afresh reads its
candidates. On iOS the per-game candidate shortlists are carried from the last
pass while the channel list and guide are the same ones (the index generation)
and the game's identity is unchanged. Within a generation the guide only loses
listings as they end, so a carried shortlist holds every channel a rebuilt one
would. The word indexes are built only for a game without one: the first pass
of a generation, or a game new to it. The Channels list keeps its hints either
way.

College games keep their matches the way every other league does: the
signature is the game's identity plus whether it is delayed, and the kept
channel must still score. They used to be scored against the whole college
pool, or its shortlist, on every pass.

Restored matches are given the signature a pass writes. They were given an
older form, which no pass matched, so the first pass after every launch looked
for every restored game again.

Launch Timing's "candidate scores" line says how many channels and guides a
pass read, how many college matches it kept, and whether shortlists were
carried or rebuilt.
