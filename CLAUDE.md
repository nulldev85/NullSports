# Notes for Claude

## Tester notes site

The release notes for testers live at https://nulldev85.github.io/, served by
GitHub Pages from the `main` branch of `nulldev85/nulldev85.github.io`. That
repo holds one self-contained page, `index.html`, and `.nojekyll`. A push there
is live a minute or two later; nothing in this repo deploys it, and it stays up
while this repo is private.

Every merge round into `main` ends with updating that page:

- Add each new feature as an `<article class="entry">` in its section (Sports,
  Library, Player, Under the hood), written for testers: what it does, then
  "how it works" in plain words, then the tech line. Copy an existing entry.
- Set `data-platform` (`iphone`, `tv`, or both) and `data-release` to the PR
  number, and list the commits in `.shas`.
- Add the release to the ledger at the top of the Releases list, newest first.
- Update by hand the tally under the title, the eyebrow's date range and the
  footer's date. The filter and ledger counts recount themselves on load.
- Push to `main` of that repo and give the user the link with the build links.
