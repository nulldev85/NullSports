# iPhone concurrent IPTV providers — build 142

Settings → IPTV now has an independent enable switch for each saved account.
Existing accounts start enabled. Sports, TV Guide and Search combine enabled
providers' live channels. The user explicitly chose a combined TV Guide, rather
than browsing only one provider there. Category names identify their service;
Favorites and Recents can contain channels from different services together.

Selecting a feed keeps the preferred account unchanged. The existing checkmark
still selects the preferred account for provider VOD and provider-scoped Settings
lists. This change combines live IPTV sources; it does not extend VOD search to
every provider. Existing provider VOD results now name their actual source too.

Sports uses the Guide's separate provider row directly below the preview and
its existing fullscreen capsule beneath the badges. Search results show the
provider for channels, programmes and matched events. When two services have a
feed for the same event, both can appear with distinct identities. Unmatched
events explicitly say no provider feed has been matched. Search keeps its full
existing player, PiP controls and dismissal gesture, with a provider capsule.

## Source ownership

- Each enabled provider has a separate native catalog, credentials and strict
  sports matching context. A stable device-local registry assigns combined
  display IDs; native channel numbers, category IDs and EPG IDs remain scoped
  to their original account. Display IDs are never sent to a provider.
- Playback, automatic quality checking, catch-up URLs, archive listings,
  favorites, recents and saved feed choices route back to the native context.
  Multiview can use two different accounts without changing the preferred one.
  Its tiles identify their providers as well.
- Combined favorites/recents ordering and selected game/team feeds use separate
  persistence keys. Per-provider keys retain native IDs. Existing category
  defaults migrate to the qualified category of their own account; a long press
  can choose a default category belonging to any enabled service.
- Team-follow actions and schedule refreshes retain the existing root store.
  Removing a preferred account's saved channel choice or recents in Settings
  also retires its combined display entry, leaving other providers intact.
- Disabled/removed accounts cannot generate new playback URLs or publish late
  metadata. Their active player/tiles close or stop; other accounts continue.
  Turning a service off retains its saved login and native favorites.
- Metadata errors retain already-browsable channels and their source URLs,
  but retire that service's automatic event evidence until it validates again.
  Working services remain available. Guide and Search identify failed services.
  Cached primary channels remain browsable during startup validation.
- The existing metadata actor coalesces duplicate requests, bounds concurrent
  downloads to two and retains at most three snapshots for two minutes. It does
  not open/probe video streams to build the combined catalog. Strict matching
  uses native category names; provider display names cannot become evidence.

## Validation

Local metadata/resource and source-membership tests: 12 passed. Playback project,
engine pins, tvOS focus and whitespace checks passed. Windows has no Swift/Apple
SDK; compilation and all new SDK tests remain pending the actual IPA workflow.

Eleven new iOS model/store regressions cover colliding native IDs and authentication,
isolated EPG/category/search identities, favorites/recents and registry relaunch,
enable persistence, account removal during discovery, category-default migration,
partial failure, matching isolation, metadata refresh failure and existing team/
Settings behavior, including migration of existing favorites/recents ordering.
A further real playback regression opens the same native
channel number from two local provider origins, requires two independent Aether
sessions with rendered pictures and advancing clocks, and checks that the
preferred account never changes. It uses the existing MPEG-TS fixture and full
playback readiness assertions. All existing tests remain enabled.

This extends passed build141 and includes the prior unmerged iPhone navigation,
category defaults, tracking, UFC and tester playback/provider fixes. tvOS remains
build91. No merge or shipping distribution has been performed; Seerr remains
deferred as requested. Private tester services and device playback have not been
verified locally.
