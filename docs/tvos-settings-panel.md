# Apple TV settings panel

The reference is a single large translucent blue-gray panel: categories on the
left, a spacious settings list in the middle, and a description rail on the
right. Lineup uses the existing native top tabs above that panel. The background
is a quiet gray-to-blue gradient, with a thin panel edge and pale blue focus.

Only the middle settings list scrolls. The sidebar adapts its row height to keep
all eight categories visible on smaller TV viewports. Focus previews a category;
rightward remote navigation enters its controls. A selected category remains
marked when focus moves into the list. The description rail explains the focused
control. Reduce Transparency uses an opaque panel with the same geometry.

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

Local validation checks Swift syntax, the TV focus rules and source membership.
TV SDK coverage hosts every category with saved providers, servers and independent
engine choices, checks that scrolling stays between the two fixed side columns,
and attaches native screenshots of all eight pages to the TV test result. The
viewport checks include HD, Full HD and 4K proportions. Full SDK execution and
device appearance review require the review build.

Release notes:

- Settings has a new translucent panel with a category sidebar, cleaner rows and
  descriptions beside the selected controls.
- Existing settings are organized into eight sections, with the category list
  staying visible while you scroll through an individual section.
