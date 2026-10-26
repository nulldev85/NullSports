# Live playback and presentation overhaul — iPhone144 / tvOS92

The user reported more live Sports feeds failing since quality verification was
added. Manual selection only sometimes worked. They also requested that menus
and popups match Sports and TV Guide, explicitly on both iPhone and Apple TV.
This extends passed iPhone143, exact `7a46519`, without merging the review branch.

## Start the selected feed without extra video connections

The previous automatic path demux-probed several candidate URLs before opening
the player. Even bounded/closed inputs cause extra provider connections before
the actual session, a poor fit for connection-limited services. It also rejected
a selection solely because the catalog index generation changed while checking.
The user's private provider failure has not been directly reproduced here;
these are identified code-path hazards, not a claim about their server's logs.

- Automatic quality selection now uses a separate cache of **rendered playback**
  measurements. Cold/unknown feeds retain the existing verified event match;
  no quality probe opens another stream at startup. This intentionally does
  not scan unplayed alternatives to discover their quality before playback.
- Existing players report width, height and frame rate only while live video
  is playing and has actually produced pictures. Recordings, VOD, audio-only
  sources and opening metadata do not populate this cache. Reporting cannot
  retune, change engines or create any media connection.
- Measurements expire after ten minutes, are bounded to256 URLs and survive
  relaunch. Keys hash the complete exact URL, including account identity and
  credentials; raw URLs/account names/secrets are not persisted. Nonfinite
  frame rates are sanitized. Duplicate metadata ticks do not rewrite the cache.
- A real initial playback failure retires that URL's confirmed measurement,
  leaving other accounts/URLs intact. Language preference still takes priority.
- A cached URL variant remains first in the live player's candidate queue,
  including retries. Fresh Xtream URL lists still prefer HLS as before. Library
  ordering, selected engines, PiP, stats, source ownership and catch-up remain.
- Selection revalidates the current event and exact source. An unrelated index
  rebuild cannot discard an unchanged verified fallback. A retired cached
  upgrade falls back to the still-valid original; changed/disabled accounts,
  changed events and unverified sources still cannot authorize playback.
- The existing bounded probe API and tests remain for explicit callers. Normal
  automatic Sports/Guide/Search quality selection does not invoke that API.

## One presentation family

`LineupPresentationStyle` supplies near-black backgrounds, charcoal cards,
subdued SF Pro Rounded text, soft icon tiles, continuous corners, quiet dividers
and tinted selection rows. The palette is shared between platforms. Sports'
held-event menus use their league color; event-channel rows retain official
logos with the Guide's logo-derived dark tint. No artwork was replaced/generated.

The shared dropdown, hold-menu and choice-sheet renderers cover category/view
menus, playback options, feed choices, confirmations and Library actions.
Sheets/fullscreen destinations receive a shared presentation scope without
changing their content, bindings or dismissal callbacks. Dedicated channel/
catch-up, subtitle, source, favorites, shelf, collection, setup, accent, license,
team and racing surfaces use the same palette. Settings and status/error/loading
surfaces are included. Main Library/Sports/Guide layouts retain their existing
geometry and artwork, and tvOS retains its single focus layer and Back behavior.

iPhone rename/create alerts now use a themed native text-entry sheet with the
existing validation and save/cancel callbacks. Keyboard submission follows the
same validation; dismissal preserves cancellation cleanup, and rapid Save taps
cannot invoke the commit twice. Destructive choices retain their confirmation
and their existing action. No provider/server credentials or deletion code changed.

## Validation

Local metadata/resource and shared source-membership tests:12 passed. Playback
project checks, engine pins, expanded tvOS focus audit and whitespace checks
passed. The current origin/main is an ancestor of the review branch.

Six new SDK regressions cover zero-probe cold startup, exclusion of demux-only
quality, exact-URL selection, language/account/expiry/relaunch isolation,
failure retirement, real-picture reporting gates and live-vs-Library URL order.
Existing source/matching, native playback, tracking, provider and menu tests stay
enabled. No assertion/test exclusion/deadline was weakened or workflow changed.
Windows has no Apple SDK; compilation, SDK tests, native visual/device review
and private-service behavior remain pending the two IPA workflows.
