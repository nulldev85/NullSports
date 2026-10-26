# Notes for Claude

## Releases, notes and the site

Testers install Lineup from the AppSource feed, `apps.json` in
`nulldev85/AppSource`. The same feed drives the hub at
https://nulldev85.github.io/ (`nulldev85/nulldev85.github.io`, one
`index.html`).

- A push to `main` here builds the official IPAs. Each build's
  `source-release` job publishes a `source-*` release whose `Source-*` lines
  name the app, bundle id, version, build and commit.
- AppSource's "Update app source feed" workflow (every 30 minutes, on its own
  pushes, or by hand) copies those IPAs into AppSource's releases and writes
  `apps.json`. It lists a build only once it has written notes.
- Every merge round into `main` ends with notes in AppSource's
  `release-notes.json`: an entry per app with its bundle id, version, build and
  the full merge-commit SHA, since build numbers get reused. Keep iPhone and
  Apple TV apart. Write for testers: what they can do now, or what stops going
  wrong, in plain sentences; no commit titles or internals. Raise the catalog
  count in `tests/test_release_notes.py` and run
  `python -m unittest discover -s tests -b` there before pushing.
- The site reads builds, download links and notes from the feed as it loads.
  Only the app descriptions and feature cards are written by hand, so keep
  them true to the apps. The page's built-in builds and notes are what shows
  if the feed can't be reached; refresh them to the newest release.
- Build numbers are set by hand in `project.yml` (`CURRENT_PROJECT_VERSION`,
  Apple TV and iPhone). A release that keeps the last one's numbers may not be
  offered to testers as an update by their signer.
- The site repo's `publish-builds.yml` belongs to the old single-page site;
  the download buttons no longer use its releases.
