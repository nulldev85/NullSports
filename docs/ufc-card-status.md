# UFC cards disappearing after a prelim

On October 24, 2026, the public ESPN UFC scoreboard returned event 600061267,
UFC 333: Volkanovski vs. Evloev, with card state `in`. Its first nine bouts were
already `post`; later bouts remained `in`/`pre`. No bout contained
`matchNumber`. Lineup selected the first bout and preferred its `post` status
over the event's `in` status. SportsLibrary correctly excludes completed
events, so the misclassified card disappeared after the fresh schedule arrived.

The shared schedule parser now honors the card's live/final state independently
of the bout used for fighter artwork. With no usable card state, any active
bout keeps it live; it is final only when every bout has a known final state.
Between fights, the existing bounded start-time policy still applies. Explicit
final/canceled cards stop showing as live. No cache retention workaround,
hardcoded event, changed playback, or relaxed channel matching is involved.

When bout-order numbers are missing, headline fighter names in the event title
identify the matching bout; known match numbers retain their existing priority.
This prevents a finished prelim's fighters from replacing the actual headliners
in channel matching and artwork. The full event name supplies fallback names.

`Tests/tvOS/Fixtures/ufc333-live.json` contains a reduced public response from:
https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard?dates=20261024
Only fields used by the decoder are retained. Both platform test bundles
already include this Fixtures directory. Ten shared SDK regressions cover the
actual response, changed bout order/results, explicit final/canceled states,
missing/lagging event state, incomplete bout state, future cards, match numbers,
malformed responses and legitimate empty days. No test is disabled or weakened.

The fix is on `codex/ufc-card-status`, based on the current pending MDBList
repair `70ddd48`. It preserves all pending tracking and iOS changes. Separate
branch builds do not cancel the earlier MDBList workflows. No merge is
authorized or performed. Local project/source membership, metadata, engine
pin, tvOS focus and diff checks pass. Windows has no Apple SDK; Swift tests,
IPA packaging and device verification remain pending CI/user results.
