# Event Channels and automatic quality

iPhone Sports live-card menus now include **Channels**. The sheet lists only
channels accepted by that event's existing matcher, with the provider logo,
channel name, current program, provider-advertised quality/rate, and a play action.
The list scrolls, uses Lineup's charcoal panels/accent controls, and revalidates
the selected channel before playback. Choose Another Channel remains the broad
manual search for provider feeds whose guide is missing or differently named.

Matching runs off the main actor and is canceled/replaced when the provider,
guide or schedule changes. No source connections or media probes are opened to
populate this list. Radio, replays, another matchup, and another racing session
cannot qualify merely by advertising a higher resolution. College keeps its
strict matcher and disallows broadcaster-only fallback; its scan also covers
verified event channels without a league/category token.

Both platforms rank automatic matches and alternate feeds by the existing
English-language preference, then advertised resolution and frame rate, then
matching-evidence strength, then stable provider ID. 4K/UHD precedes FHD/1080p,
HD and SD; explicit rates break resolution ties. Unknown quality stays unknown.
Provider HD/SD labels are displayed as HD/SD, not invented measured pixel counts.
These hints do not claim bitrate, HDR, Atmos, or actual decoder output; the
existing playback-info badges continue reading confirmed source metadata.

Explicit game/team selections and successful recovery feeds retain their normal
priority. Ordinary automatic playback no longer saves itself as an exact-game
manual pin. Automatic match identities/signatures include a policy revision so
the previous provider-ID-ranked cache is rematched. Full channel/guide index
refreshes invalidate retained match signatures as before. Existing exact-game
choices remain scoped to their original game and expire normally.

The iPhone soccer-competition chooser now presents through the tab-root menu
host. Its previous button-local overlay was confined to its Live tab header
or rounded Settings List row. Both locations use that root host; tvOS retains
its native full-screen choice presentation.

Shared XCTest coverage exercises quality/rate parsing, honest unknown labels,
event-only filtering, a higher-ID 4K feed winning over HD, strict college
selection, duplicate IDs, language preference, and race-session separation.
iPhone additionally checks all 18 competition choices and their original
selection binding. Apple SDK compilation and device layout review run through
the review builds; local Windows checks cannot establish those results.
