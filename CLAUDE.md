# Notes for Claude

## Tester notes site

The release notes for testers live at https://nulldev85.github.io/, served by
GitHub Pages from the `main` branch of `nulldev85/nulldev85.github.io`. That
repo holds one self-contained page, `index.html`, and `.nojekyll`. A push there
is live a minute or two later; nothing in this repo deploys it, and it stays up
while this repo is private.

The page has its own look, not the app's. It is dark only and monochrome,
warm white on near-black, with no accent colour. Archivo at full width is for
the loud words, Geist for reading, and Geist Mono for versions, SHAs and
dates. Motion is quiet and eased. The top has no headline: a caption, the
intro and the hero stats, which count from the page itself, over a dot field
lit by slow light and the pointer. Downloads are two cards filled from the
site repo's releases, with each device drawn in hairlines around the app's
own icon, drawn again each time a card comes back into view or the page comes
back to the front; the Apple TV box's light comes on once it is drawn. The app icon is also the top
bar logo and the tab icon. All of them are small PNGs inside the page, cut
from `iPhone/Assets.xcassets/LineupAppIcon.appiconset` and the flattened
Apple TV brand assets, so a new icon means new copies there. Feature cards keep one markup,
`.meta` (`.plats`, `.rels`, `.shas`) then `.copy` (`h3`, `p.lede`, `dl.how`
or `ol.steps`, `p.stack`), so anything added copies an existing card and uses
those classes.

Every merge round into `main` ends with updating that page:

- Add each new feature as an `<article class="entry">` in its section (Sports,
  Library, Player, Under the hood), written for testers: what it does, then
  "how it works" in plain words, then the tech line. Copy an existing entry.
- Set `data-platform` (`iphone`, `tv`, or both) and `data-release` to the PR
  number, and list the commits in `.shas`. A feature that reached each app in
  a different release also gets `data-release-iphone` and `data-release-tv`.
- On a card for both apps, mark any line true of one app only with
  `data-only="iphone"` or `data-only="tv"`, so each filter shows only its own.
- Add the release to the ledger at the top of the Releases list, newest first.
- Update the footer's date by hand. The filter, ledger and hero counts
  recount themselves on load.
- Push to `main` of that repo and give the user the link with the build links.

The page's Download panel offers the newest official IPA of each app, from the
site repo's releases. Once the official builds on `main` pass, run that repo's
"Publish official builds" workflow (`publish-builds.yml`, workflow_dispatch) so
the new IPAs go up straight away; it also runs hourly. It reads this repo's
builds with the `NULLSPORTS_ACTIONS_TOKEN` secret in the site repo, a
read-only Actions token the owner made.
