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
as accessibility hints. Reduce Transparency uses an opaque charcoal panel with
the same geometry.

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

Local validation checks Swift syntax, the TV focus rules and source membership.
TV SDK coverage hosts every category with saved providers, servers and independent
engine choices, checks that scrolling stays beside the fixed sidebar and inside
the panel margins,
and attaches native screenshots of all eight pages to the TV test result. The
viewport checks include HD, Full HD and 4K proportions. Sports regressions check
palette stability/fallbacks, render the background while changing the highlighted
event, verify it remains dark, and attach red, blue and empty-state screenshots.
Full SDK execution and device appearance review require the review build.

Release notes:

- Settings has a new charcoal panel with a category sidebar and cleaner rows,
  using the same colors as the rest of Lineup.
- Existing settings are organized into eight sections, with the category list
  staying visible while you scroll through an individual section.
- The Sports background now follows the highlighted event's dark team-color
  blend, with a smooth transition as you browse.
