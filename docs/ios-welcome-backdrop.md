# iPhone welcome backdrop

The first-launch poster field now uses twelve bundled official TMDB posters,
alternating movies and television series. It performs no catalog or image request
and draws complete artwork on its first layout, including with no connection.
The unchanged TMDB attribution remains in the welcome form. The original CDN
URLs, title IDs and SHA-256 checksums are recorded in
`BuildAssets/WelcomePosters.json`. The twelve JPEGs total 476,558 bytes. None is
AI-generated.

`MobileWelcomePosterCanvas` owns six fixed, individually clipped row layers.
Core Animation animates only their horizontal track transforms, with linear
24-point-per-second travel and alternating direction. Three identical copies
cover every phase of a strip. Artwork is shared between layers and cannot be
evicted by the network image cache. Form edits do not recreate or restart rows.

The active-time clock pauses on detachment, UIKit inactivity or the SwiftUI
scene becoming inactive. Reattaching/resuming installs animations at the saved
phase. Layout changes rebuild layers without implicit animation and reuse that
clock. A newly created welcome screen starts with complete local artwork and a
fresh clock. Reduce Motion retains the complete static artwork.

Provider forms, official Lineup branding, playback, library behavior and tvOS
are unchanged.

Validation:

- Local asset validation checks all twelve hashes, JPEG dimensions, source hosts,
  movie/TV mixture and asset catalog references; no network is used by the check.
- The Foundation preflight samples three full loops across five viewport widths,
  checks immediate travel/direction and exercises update/pause/resume semantics.
- Three simulator tests check the real app-bundled images on first layout, real
  presentation-layer movement in all six rows, repeated updates, pause/resume,
  resizing, detaching/reattaching, creating a new view and updating the SwiftUI
  bridge without losing its canvas or restarting motion. Startup and reopened
  screenshots are attached to the normal navigation-previews artifact.
- Windows can run the source/resource checks. Swift compilation, simulator
  execution and the installable IPA are validated by the normal iPhone workflow;
  do not describe those results as passed before CI/user feedback.
