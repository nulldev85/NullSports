# iOS 148 login controls

Three presentation-only adjustments follow the supplied device screenshots:

- Seerr's account choices show original-color official marks for Seerr, Plex,
  Jellyfin and Emby, fitted to a 22-point square. API Key keeps a key symbol.
  All five methods remain in the same horizontal row and keep their existing
  actions/bindings. Intrinsic labels and small content insets prevent the first
  choice from clipping against the scroll edge. Selection retains its check and
  accessibility trait. The Seerr PNG is unchanged official upstream artwork;
  its Git blob hash and size were verified, and attribution/license are bundled.
- The non-glass navigation bar has no selected-tab fill or outline. The selected
  icon remains accent colored. Glass appearance, outer panel, labels, destinations,
  tab ordering, compact-on-scroll, retap and fullscreen rules remain.
- iOS integration actions use content-sized rounded buttons with 14-point side
  padding, 8-point vertical padding and a minimum 44-point touch target. Removed
  competing full-width frames and redundant label padding. Silo account/API-key,
  profile and connect actions and Jellyfin/Emby/Plex connect/link choices use the
  tighter treatment. Long generic labels may wrap; sign-in method labels retain
  their intrinsic width in the scroll row. Brand tint, disabled/busy states and
  existing authentication/profile/session logic are unchanged.

TV keeps its existing control/focus style through platform guards. This branch
starts from the TV96 repair so that work is retained for eventual consolidation,
but only the iPhone version changes (148); no TV build is dispatched or polled.
No new view-appearance tests mirror these reversible styles. Existing navigation,
integration, source membership and full SDK suites remain enabled. Local source,
asset, YAML, packaging/pin, focus and diff checks run on Windows; Apple SDK/device
layout verification requires the actual iPhone IPA build. Review all five Seerr
choices, the four media-server sign-ins, long names and larger text sizes on device.
