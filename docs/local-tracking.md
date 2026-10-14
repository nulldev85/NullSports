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
- Hidden unfinished positions survive the normal 200-record recent-history
  limit. Clear Local Tracking clears positions, watched status, and dismissals;
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

On each device, play part of a movie and an episode, remove both from Continue
Watching, refresh the Library, and relaunch. Both should stay hidden. Open their
detail pages and resume: the movie's time and show's episode should be retained.
After playing for at least five more seconds, the appropriate cards should
return. Check that finished episodes remain watched throughout.
