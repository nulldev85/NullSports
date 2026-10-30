# Apple TV Settings and Sports backgrounds

Settings retains the reference's large rounded panel, fixed category sidebar
and spacious list. Its colors now come from Lineup's existing charcoal ground,
surfaces, text and accent tokens. The right-hand description area and bottom
tagline are removed; the settings list uses the space they occupied. Lineup
keeps its existing native top tabs above the panel.

Only the settings list scrolls. The sidebar adapts its row height to keep
all eight categories visible on smaller TV viewports. Focus previews a category;
rightward remote navigation enters its controls. A selected category remains
marked when focus moves into the list. Control explanations remain available
as accessibility hints. The charcoal panel uses an opaque surface, retaining its
geometry and border without a nearly hidden full-panel backdrop blur.

Existing options are grouped as follows:

| Category | Existing options |
| --- | --- |
| Servers & Sources | Set Up with iPhone; TV source connection, switching, refresh, Guide and removal; media server connections, counts, reload, browse, add and removal |
| Playback | Existing Sports, TV Guide, Library and Search engine choices |
| Library | Hero catalog, metadata, collections, shelf add/remove/order, Seerr, MDBList and its account information, tracking, refresh and clear-local-tracking confirmation |
| Sports & Teams | Followed teams and preferred channels |
| Appearance | Existing accent presets, custom colors and saved colors |
| iCloud | Existing sync status |
| Diagnostics | Channel matching, launch timing and playback log |
| About | Version, build and playback acknowledgements |

Source stores, saved engine keys, setup destinations and confirmation sheets are
unchanged. This does not add the reference app's playback switches or picture
processing features. iPhone settings and playback code are outside this change.

Sports uses the same away/home team-color wash for matchup cards and the tab's
background. The existing highlighted-event model drives that background from
both the main event list and My Teams. Changing focus crossfades the wash over
0.45 seconds; Reduce Motion removes that animation. Score/clock updates retain
the same color identity. Missing colors use the card's existing league/away-color
fallback, and an empty event list returns to the neutral background. These
presentation updates do not change or retune playback.

TV refresh work keeps remote navigation available. Saved-match reconciliation
and playlist decoding run off the UI actor. Provider data and retired channel
proof are installed together after checking snapshot revisions, so an older
validation cannot restore a retired feed or cross a provider switch. Full
matching requests share one worker and combine pending requests into a follow-up;
newly live games retain their independent priority path. Superseded index and
matching workers are canceled. Daily preparation uses fresh local inputs rather
than triggering repeated provider downloads; genuine catalog/guide expiry and
near-kickoff top-ups still refresh the provider. The refresh popup remains scoped
to TV Guide.

The Sports tab renders one page background. Color changes retarget one persistent
gradient from its currently displayed colors, replacing the same animation key
instead of accumulating outgoing full-screen transitions during rapid browsing.
The dark wash, vignette, row colors and 0.45-second motion remain. Reduce Motion
also stops an in-flight transition when the highlighted game stays the same.

Local validation checks Swift syntax, the TV focus rules and source membership.
TV SDK coverage hosts every category with saved providers, servers and independent
engine choices, checks that scrolling stays beside the fixed sidebar and inside
the panel margins,
and attaches native screenshots of all eight pages to the TV test result. The
viewport checks include HD, Full HD and 4K proportions. Sports regressions check
palette stability/fallbacks, render the background while changing the highlighted
event, verify it remains dark, and attach red, blue and empty-state screenshots.
Four refresh tests compile and execute locally against the app's real Foundation
models, covering download policy, 32 concurrent matching requests, provider-reset
races and guide/channel retirements with saved alternatives. The TV workflow runs
the same tests before its SDK build. Native coverage also checks 200 rapid palette
changes keep one gradient layer and at most one animation. Full SDK execution and
device responsiveness review require the updated review build; no device frame
rate or latency measurement is claimed by the local checks.

Release notes:

- Settings has a new charcoal panel with a category sidebar and cleaner rows,
  using the same colors as the rest of Lineup.
- Existing settings are organized into eight sections, with the category list
  staying visible while you scroll through an individual section.
- The Sports background now follows the highlighted event's dark team-color
  blend, with a smooth transition as you browse.
- Background channel work shares matching passes and avoids unnecessary repeat
  downloads, with less rendering work while navigating Sports and Settings.
