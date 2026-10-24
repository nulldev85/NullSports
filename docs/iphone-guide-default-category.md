# iPhone TV Guide default category

Open the centered channel selector, choose Categories, and hold a category to
open Lineup's existing choice sheet with **Set as Default**. The saved category
has a small **Default** badge. Holding it again offers **Remove Default**.
A regular tap still just selects a category for the current visit.

The choice is saved locally per IPTV provider UUID and applies in both TV Guide
and List modes, including a fresh app launch and returning from another tab.
Returning to Guide replaces a temporary manual selection with the saved default;
the custom bar's Guide home action does the same. Without a saved preference,
existing behavior is retained: Favorites when present, otherwise All Channels.

If the chosen category is missing or its provider catalog is still loading, the
Guide falls back to Favorites/All until that category is available. It retains
the preference through temporary catalog failures. Xtream and M3U category IDs
are both supported. A saved choice cannot cross providers or apply to the sports
game channel picker. A stale menu action rechecks provider/category identity.

Search still searches every channel. Guide ordering, views, catch-up, favorites,
playback and tvOS behavior are unchanged. This branch includes the pending iOS
scrolling-navigation changes from build130 without cancelling that build.

Six SDK tests cover persistence/relaunch, real menu action dispatch, independent
provider preferences, delayed/missing catalogs, existing fallback behavior,
manual selection versus default, removal, game picker isolation and malformed
preferences. Existing full SDK and navigation tests remain enabled. Windows has
no Apple SDK; these six tests and device interaction remain pending the normal
iPhone IPA build. Local validation passed: 10 metadata/source-membership tests,
playback project/version checks and `git diff --check`.
