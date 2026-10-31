# Apple TV live preparation and the 99% indicator

The user confirmed TV724 fixed the broad navigation lag and requested only the
remaining live-event sync delay. TV724's full workflow passed at 7e960b6.
The working iPhone implementation, TV rendering/navigation and player settings
are preserved by this follow-up.

## Findings

TV still used a separate progress object that advanced from elapsed time and
the previous run's duration, stopping at 99% until all work ended. Indexing,
matching, and parsing could therefore keep showing an estimated 99% regardless
of their real progress. Its matching lifetime was tied to a global work count,
so overlapping passes could keep that indicator open.

TV's full matching pass also rejected its entire answer if any event identity
changed while it ran. A change to one game's broadcast/start/venue could
discard valid results for the rest of the slate and prevent the daily snapshot
from advancing. The TV worker lacked the conservative candidate shortlists
already used by iPhone, increasing the work that had to finish before saving.
These are confirmed source differences, not a measured trace from this device.

## Changes

- Both targets now compile the exact same measured progress model. The old
  estimated TV model is removed; the iPhone source itself is unchanged. Network
  progress uses bytes when known, matching counts both primary and alternative
  passes, and parsing/indexing/publication show their actual phase. Work tokens
  stop obsolete callbacks from finishing or extending a replacement operation.
- TV uses the existing conservative candidate index and per-input shortlists.
  All retained candidates still pass the same full evidence checks. The index
  and normalized channel/guide facts are reused rather than rescoring the
  provider catalog for every game.
- Results are published per unchanged event. A changed event alone is queued
  for another pass; it cannot withdraw or prevent saving unrelated valid games.
  The daily checkpoint advances independently of those targeted follow-ups.
- TV's live-priority preparation saves each completed live game immediately
  through the bounded snapshot queue. It no longer waits for the remaining
  live/upcoming slate to finish before making those results durable.

Returning launches restore validated saved schedules/channels before provider
or full-guide responses. Selection uses that evidence while refresh runs behind
it. New providers and genuinely changed/expired events still require valid
evidence; this does not replace verification with guessed channels. Refresh
feedback remains confined to TV Guide.

## Verification

- The conditional iPhone bodies for index building, provider/Guide refresh and
  matching were compared with 7e960b6 and are unchanged. No iPhone source file
  is modified. TV's project explicitly includes the existing progress and
  Foundation candidate-index files; a source-membership regression checks both
  targets compile those same implementations.
- 35 Foundation tests, 34 repository checks and 15 saved-playback checks using
  the real models pass locally. Both target syntax parses and whitespace
  checks pass. Apple SDK execution is separate.
- Native TV progress tests cover actual bytes, unknown-size work, both matching
  passes, phase transitions, obsolete callbacks, provider changes, failure,
  cancellation and completion after publication, including capsule sizing.
- A native bootstrap regression blocks provider responses and verifies the
  saved game is visible, verified, selectable and has playback URLs before
  global matching/refresh completes.
- A deterministic native race changes one event after calculation while
  holding publication. The unchanged event must become playable while the
  changed event's obsolete result remains rejected. The publication barrier
  is nil in production; generation/profile checks still run after it.

Native results and real-device return-launch behavior remain pending the new
review build. This change does not alter navigation, the full-screen Sports
background, scores, playback quality, buffers, engine selection or the four
new soccer cups. No merge or production/VPS change is included.
