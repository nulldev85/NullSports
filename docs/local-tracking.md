# Local Library tracking

iPhone and tvOS use the same device-local `MediaLibrary` store. Progress,
watched status, and Continue Watching visibility are separate choices.

- **Remove from Continue Watching** saves a dismissal for that movie or entire
  show on its source server. It flushes the latest buffered position and keeps
  all playback records, including completed episodes. Relaunching, refreshing,
  receiving Up Next results, or opening a detail page does not unhide it.
- Opening the title from its detail page still offers its saved resume point,
  including the local episode fallback when its server is unavailable.
- A later playback session restores the card after moving at least five
  seconds from its initial position. Merely loading the saved position or
  briefly opening and closing the player keeps the title hidden. Start Over
  uses zero as its initial position.
- Each player presentation captures its item and a session ID. Closing samples
  from an earlier session cannot undo a later removal. Samples arriving after
  session end, a manual watched change, or natural completion are ignored.
- Actually playing a different episode supersedes an older queued Up Next
  marker while retaining that older episode's watched status and progress.
- Watched changes use the complete episode order to update Continue Watching,
  show Play buttons, status badges and the next thumbnail together. A detail
  page reads the shared store directly. The focused tvOS preview follows a
  replacement episode even when its focus slot stays the same.
- Local viewing history determines the next episode. A server's later Next Up
  or watched flags for later episodes cannot skip ahead of the local position.
  With no local history, the server's state remains the fallback. A new manual
  unwatched choice returns to that episode; completing a later episode moves
  past older partial progress while retaining its position for deliberate replay.
- Complete episode metadata learned during this session permits immediate
  advancement and thumbnail replacement without a network response. Late
  responses reconcile against current records rather than an old snapshot.
  An invalid legacy marker is hidden until the full episode order repairs it.
- Hidden unfinished positions, queued episodes and watched/unwatched truth
  survive the 200-item recent-history limit. Clear Local Tracking clears
  positions, watched status, and dismissals;
  removing a media server clears that server's records and dismissals.

Playback data stays under the existing `Lineup.localMediaPlayback.v1` key.
Dismissals use `Lineup.continueWatchingDismissals.v1`; existing playback data
needs no migration. Records deleted by an older build cannot be reconstructed.
Show matching uses server plus series ID, with a normalized name fallback when
an ID is missing. Different known series IDs and different servers stay separate.

## Validation

`Tests/iOS/LocalMediaTrackingTests.swift` runs in both the `LineupiOSTests` and
`LineupTests` simulator targets. It covers saved positions and removals across
relaunches, whole-show scope, refreshed Up Next, stale callbacks, real resume
and Start Over, brief opens, repeated removals, manual watched changes, server
isolation, metadata enrichment, retention, completion, and clearing history.
`SeriesResumeTests` and `SeriesTrackingConsistencyTests` also run on both
platforms. They cover the S02E10 jump after E02, remote flags ahead of local
progress, menu changes while offline with an episode list already loaded,
out-of-order responses, thumbnail replacement, season boundaries, whole-show
marks, server isolation, name-only legacy records, provider episode menus,
completion callbacks, retention and relaunch.

On each device, play part of a movie and an episode, remove both from Continue
Watching, refresh the Library, and relaunch. Both should stay hidden. Open their
detail pages and resume: the movie's time and show's episode should be retained.
After playing for at least five more seconds, the appropriate cards should
return. Check that finished episodes remain watched throughout.

On Apple TV, mark the current Continue Watching episode watched without
moving focus: its next episode and still should replace it. On the show page,
mark several episodes watched, mark an earlier one unwatched, and check the
Play target and checkmarks after each edit. Return to Library and relaunch;
all positions should agree. Repeat at a season finale and with the server
unavailable after opening the show once in the same session.
