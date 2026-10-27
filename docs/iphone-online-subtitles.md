# Built-in OpenSubtitles on iPhone

Library movie/episode playback offers **Subtitles > Find Subtitles Online**.
No end-user account or API-key entry is required. The Lineup consumer key is
injected by Actions secret LINEUP_OPENSUBTITLES_API_KEY into the existing ignored
LineupMetadata.json resource. App consumer keys are extractable from installed
applications; no account passwords, signing keys or write-access tokens belong
in this resource. The actual consumer key is not committed or logged.

Search is requested only when the user opens the online subtitle sheet or changes
its language. Movie matching uses exact IMDb identity; episode matching uses the
series IMDb ID plus exact season/episode (including supported AIOStreams packed
IDs). The existing external-ID resolver works independently of display metadata
preferences. Missing identities are reported rather than guessed from a title.
Replies with different identity/language, malformed entries and multipart files
are rejected. The first result page is shown; no automatic release selection,
alignment guess, subtitle download or background search occurs.

The styled sheet contains a language picker, release rows, hearing-impaired/
foreign-parts labels, and a **Filter releases** field. UITextField owns the
editing buffer. Keystrokes only filter downloaded result metadata off the main
actor; cancelled or superseded filters cannot publish stale rows. Only completed
result changes redraw the list, and the field itself is retained. Typing does
not call OpenSubtitles or metadata services. Rows are lazy.

Selecting a release makes a download request for its file ID, fetches the
returned official HTTPS file URL without API credentials, validates bounded
SubRip content and normalizes it to UTF-8. File validation and temporary-file
preparation run off the main actor; the source-session token is checked again
before attaching the file. API redirects cannot forward the key
to file hosting or an unrelated host. Search caches are bounded to128 entries,
10min; downloads are memory-only, at most8 entries/8MB, 10min. Repeated selection
within that cache does not spend another download allowance. No automatic
retry/login loop is introduced. Rate limits back off; download-quota errors are
shown in the sheet. Source-session tokens reject downloads arriving after a
close/retune/engine change. Owned UUID-named subtitle files are removed on stop.

AetherEngine/VLC attach the file to their current subtitle-track selection using
documented sidecar APIs, retaining their video session, position and pause intent.
Original subtitle tracks and Off remain available. The native AVPlayer
compatibility path retains its existing captions and displays a disabled online
entry explaining that AetherEngine or VLC is required. No forced engine switch
or video restart is performed. Live Sports/Guide previews and fullscreen live
playback do not request this Library-only integration.

The pinned AetherEngine 7.49.0 documents mid-session sidecars as foreground-only:
they cannot join native PiP subtitle renditions without reloading the media.
The sheet explicitly explains that downloaded captions are unavailable in PiP
for this playback. Existing PiP video/embedded subtitle paths remain intact; no
universal PiP caption support is claimed.

The owner explicitly cancelled Live Activities. No widget extension, push
entitlement, APNs credential or push backend is added.

## Validation

The supplied consumer key was stored in the repository secret. Real official
movie and exact-episode searches returned HTTP200 with expected identities.
One development download returned HTTP200 and131400 bytes of valid timed SubRip
from www.opensubtitles.com; the API reported99 development downloads remaining.
The downloaded text and temporary URL were not committed. No plan was purchased;
normal published anonymous quotas still need consideration for wider rollout.

Six new client/native-input regressions cover identities and strict replies,
anonymous request headers/cache, download credentials/cache, quotas/backoff,
URL/redirect/format safety and native edit/Clear callbacks with retained input.
The existing Aether MP4/software-MKV playback regression now attaches a sidecar
while paused and verifies session/surface/position/PiP-source retention and stale
token rejection. A new real VLC playback regression requires actual newly
discovered/selected tracks while retaining its player, session and pause intent.
All waits use actual publications or the existing bounded readiness checks.
Full SDK tests remain enabled; their results are pending the review build.

Local source-membership5, bundle9, workflow lint, tvOS focus and diff checks pass.
Four synthetic service-configuration checks verify injection/schema, the iPhone
key requirement, empty tvOS configuration, and malformed-resource rejection
without logging fixture values. The packaged iPhone resource must contain the
consumer key. No Apple SDK/Swift toolchain is available on the Windows workstation.

Official references:

- https://opensubtitles.tawk.help/article/getting-started
- https://opensubtitles.tawk.help/article/pro-packages
- https://github.com/opensubtitles-dev/opensubs-cli
- https://videolan.videolan.me/VLCKit/interface_v_l_c_media_player.html
- The pinned AetherEngine 7.45.0 ExternalSubtitleTrack / addExternalSubtitleTrack
  API source was inspected locally before using the engine bridge.
