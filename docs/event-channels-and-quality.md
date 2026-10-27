# Event Channels and automatic quality

For the current playback-confirmed quality policy and shared menu styling in
iPhone144 / tvOS92, see [Playback and presentation overhaul](live-playback-and-presentation-overhaul.md).

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

The event-only list adds conservative checks beyond ordinary automatic matching.
An EPG entry assigned to the wrong channel cannot override another named team,
an explicitly different matchup, a conflicting league/category, youth/women's
soccer context, or a different racing session. Studio shows, highlights, replays,
historical event names and expired or contradictory overlapping listings are
excluded. A non-generic program title must identify the event itself; mentions
buried in an unrelated show's description are insufficient. Recognized generic
sport titles may use their descriptions, but not a roundup naming other teams.
Clearly named event feeds with no EPG remain eligible; a stale EPG is not treated
as an absent guide. The same checks run again against the latest guide on tap.

These checks use provider channel/category names and guide data, not video-content
recognition. A provider assigning an incorrect but plausible guide to a generic
broadcaster can still be wrong. The broad manual picker remains available for
feeds excluded because their metadata is ambiguous or incomplete.

Both platforms rank automatic matches and alternate feeds by the existing
English-language preference, then advertised resolution and frame rate, then
matching-evidence strength, then stable provider ID. 4K/UHD precedes FHD/1080p,
HD and SD; explicit rates break resolution ties. Unknown quality stays unknown.
Provider HD/SD labels are displayed as HD/SD, not invented measured pixel counts.
These hints do not claim bitrate, HDR, Atmos, or actual decoder output; the
existing playback-info badges continue reading confirmed source metadata.

Before **automatic live-event playback**, both apps now use AetherEngine 7.49.0's
bounded static source probe to compare actual video dimensions, then the engine's
display-normalized frame rate, within the existing language priority.
Candidates come only from the stricter
event-only list. Each candidate's HLS/TS URLs are checked independently; the
winning URL index is retained and that exact variant leads playback's URL list.
The pinned probe normalizes the film-rate window to 23.976, except an exact
24 fps input, which stays 24; this is a ranking hint, not a raw container-rate
measurement.
The probe demuxes source media; it does not trust an FHD name,
start a player, activate audio, or perform expensive HDR/Atmos detail passes.
Sports and Search use this path; the iPhone Guide's game-alert action does too.
An existing preview being replaced is stopped before the checks. Probes are
serialized globally, including superseded requests: cancellation waits for the
old probe to return/close before another begins. Leaving the screen or
backgrounding cancels a pending selection. A changed provider, index, schedule,
or completed event cannot publish a late selection.

Each URL has a five-second input/packet/time budget; the whole comparison has
a thirty-second budget. Results are stored for ten minutes under hashes of the
provider, event, current guide slot and full candidate URL set; changed URLs or
credentials invalidate that entry. Failures remain unknown and are cached for
thirty seconds. If some sources cannot be inspected, the app selects the best
measured eligible source; if none can, it retains the existing verified match.
It cannot guarantee a higher-quality provider feed exists, predict bandwidth,
or guarantee an adaptive stream stays at its initial resolution. Player badges
continue to report the playing source, independently of this short-lived cache.
Manual game/team choices and recovery selections are not overridden. A measured
automatic winner updates the automatic match rather than becoming a manual pin.
The Channels list now explicitly calls name-derived labels **Provider FHD**, etc.
Opening that list alone still creates no probe or playback connection.

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
