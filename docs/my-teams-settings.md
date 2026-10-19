# My Teams in Settings

Both apps offer Settings > My Teams. Choose NFL, NBA, NHL, MLB, or College
Football, then select a team to follow or unfollow it. A filled accent star
means Following. Team badges, bundled league logos, type, charcoal panels
and tvOS focus use the existing Lineup components and assets.

The iPhone shows saved teams above the league list, supports search across all
leagues, and separates college football's FBS/FCS lists. Apple TV has a league
sidebar, search, a two-column team grid, and Following for managing saved teams.
Changes save immediately; Done on Apple TV closes the picker.

The directory ships with 389 teams: NFL 32, NBA 30, NHL 32, MLB 30, and college
football 265 (138 FBS and 127 FCS in the bundled 2026 directory). Team names and
codes are available offline, even when no games are scheduled. Team artwork
uses the same ESPN image URLs and cached `TeamBadge` rendering as Sports.
The league artwork is bundled on both platforms.

The directory uses ESPN's active team lists and season-specific FBS/FCS
membership. Its snapshot date and source URLs are in
`Lineup/Resources/SportsTeams.json`. To update a future season:

```sh
python3 Tools/update-team-directory.py --season 2026
```

Following calls the existing `SportsLibrary.toggleFollow` and uses the same
league/abbreviation identity as game menus. `@Published followedTeams` updates
Sports and Settings together. Existing follows, ordering, per-provider storage
and the existing iCloud settings mechanism are retained. Users need an active
IPTV provider to save; the directory remains browsable without one.

`Tests/TeamDirectoryChecks.py` checks completeness, unique schedule keys and
team/league artwork on both platforms. The shared `SportsTeamDirectoryTests`
run in both Xcode targets and check bundled assets, name/code/league/diacritic
search, immediate game-menu equivalence, persistence after relaunch, legacy
names, provider isolation, removals and the no-provider state.

Device review: follow a team that has no game today; check the filled star and
Following list, close and reopen Settings, and relaunch the app. Follow or
remove a team from a game menu and check Settings. Follow a team playing today
and confirm its game appears in Sports > My Teams immediately. Repeat on both
platforms, including college search and a second provider. Check Apple TV
remote focus between the league sidebar, search and team grid, and iPhone
large text for long college team names.
