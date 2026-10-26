# Library reliability, Seerr and Silo

Review builds: iPhone 145 and Apple TV 93, version 0.19.0. Existing Library,
playback, metadata, collections, source selection, local tracking and MDBList
features remain available.

## What changed

- Library refresh failures retain the last successful shelves and collections.
  Successful empty answers still clear their shelf. Detail lookups and inventory
  scans share work, and removed accounts cannot reappear through late responses.
- Seerr connects from Settings on both platforms, with discovery, search,
  movie/season/4K requests, availability and request management. Library and Search
  offer entry points to the same native integration.
- Silo joins Jellyfin, Emby and Plex in one horizontal server selector. All four
  sign-in panels use dark surfaces tinted to their own logo colors.
- Native Silo libraries, collections, versions, profiles, favorites, watched state
  and resume progress participate in the existing combined Library.

## Library reliability

Shelf fetches are limited to four per server while preserving shelf order. Cold
loads can show the first real shelf promptly. A failed refresh retains that
shelf's previous contents and marks the load retryable.

Concurrent detail consumers share one request and a bounded 256-item, ten-minute
cache. Metadata parent resolution shares it too. Combined inventory consumers
share one scan, including successful empty inventories. Account removal cancels
detail work and invalidates scans; generation and profile guards reject late
answers. Snapshot writes are serialized per source and deletion waits for pending
writes, preventing an old save from recreating a removed source's cache.

## Seerr

Open Settings > Library > Seerr. Connect a configured Seerr instance using a
local account, Plex code, Jellyfin/Emby account, or API key. Jellyfin/Emby use the
media server already configured in Seerr; connecting does not configure or replace
that server. Plex linking uses Seerr's own client identifier. Uninitialized Seerr
instances must be configured in their web app first.

Connection configuration stays in device defaults; API keys and signed session
cookies stay in Keychain. Connections use isolated ephemeral sessions without
shared cookie storage. Disconnect invalidates the client and clears credentials.
Changing accounts invalidates visible account-specific results and actions.

Discover & Request has Movies and Series tabs, debounced search, official TMDB
artwork and pagination. Title pages show server availability, current requests,
quota and eligible seasons. Requests use exact TMDB identities. Library detail
entry points first resolve that identity; unresolvable titles offer search.
Search also offers an explicit Seerr search using the current term.

Standard and 4K permissions are checked independently. Immediately before a
request, the client rechecks permissions, quota, availability and existing active
requests. Season requests only include real, eligible seasons. Advanced users can
choose configured Radarr/Sonarr servers, quality profiles, destination folders
and available language profiles. These selections are validated against live
server responses before submission; server defaults remain an option.

The request queue supports filters, pagination and refresh. Users can cancel
their pending requests; managers can approve, decline, retry failed requests and
remove requests. All mutations require confirmation and fresh permissions. A
timeout is reported without blindly repeating a potentially successful write.
Rate limiting honors Retry-After. Current Seerr status enums were checked against
server source as well as OpenAPI because older docs differ for blocklisted and
deleted media.

## Native Silo

Choose Silo in Add Media Server. Sign in with account credentials or an API key,
then select a household profile and unlock its PIN when required. Account and
content IDs remain opaque strings. Credentials and profile proof are stored in
Keychain; refresh-token work is coalesced and can persist only for a connection
that still exists. API calls carry Bearer authorization, profile identity and
profile proof in headers, preserving reverse-proxy prefixes.

The native v2 adapter supports catalog browsing, series/seasons/episodes,
cursor-based catalog pagination, search, personal and curated server collections,
artwork, library counts, version lists, favorites and watched actions. Browsing
versions does not start playback. Native server history and favorites have
separate source-scoped caches. Failed refreshes retain them; merging remote
progress never overwrites saved local history, and newer foreground playback
wins. Native Silo state works independently of the existing local/MDBList toggles.

Selecting a version negotiates a protocol-v3 playback plan for that exact file.
The client declares conservative device/engine capabilities without fabricated
HDR or passthrough validation. Server-signed media URLs are used; API credentials
are not appended to media URLs. Unsupported plans report an actionable error.

The full source duration and timeline offset come from the plan, not the growing
length of a remux playlist. Remux seeks are debounced server reanchors; direct
full-timeline playback keeps normal engine seeks. Native progress and stop use
sequenced acknowledged writes. Explicit Retry obtains a fresh attempt and signed
URL at the source position; repeated taps coalesce. Closing/removing the source
prevents a delayed planner response from starting hidden playback.

PiP retains the existing playback-session lifetime. External captions retain
their original bytes and are rebased to the current remux clock after a seek;
selection, Off and timing delay are restored when the engine can attach them.
Existing engine/platform subtitle limits still apply. Neither integration
changes the app's playback engine versions.

## Styling and attribution

Setup, browsing, requests, errors and confirmation menus use Lineup's existing
dark presentation surfaces, rounded heavyweight font and shared focus treatment.
All four server tiles remain in one row on iPhone and Apple TV. Jellyfin uses
purple, Emby green, Plex gold and Silo blue for their sign-in panels and controls.
The official Silo logo is bundled, with attribution and its upstream license in
`Lineup/Resources/IntegrationNotices`. No generated movie artwork is used.

## Validation and device checks

Four Library reliability SDK tests and thirteen integration SDK tests cover
shared work, removal, empty/failing shelves, authentication, permissions, quotas,
advanced options, exact IDs/seasons, pagination, profile proof, server history,
remux clocks/seeks/progress, explicit retry and caption rebasing. Both targets
include them. Existing SDK suites remain enabled.

Local Windows metadata, source membership, packaging, displayed engine versions
and tvOS focus checks pass. Windows has no Swift/Apple SDK: the new Swift and SDK
regressions await the actual GitHub IPA workflows. Private Seerr/Silo server and
device behavior has not been independently exercised here.

Device review should cover:

1. Refresh populated shelves through a server outage, then recover and remove a
   source while details load. Existing sources and saved rows must remain intact.
2. Connect Seerr as a normal user and manager. Search, request a movie and selected
   seasons, switch standard/4K, test quotas/options, approve/cancel, then disconnect.
3. Connect Silo with password and API key, select protected/unprotected profiles,
   browse collections/episodes and choose an exact file version.
4. Resume, seek a copy-remux, pause, attach captions, seek again, retry, enter/exit
   PiP where supported, close and relaunch. Compare the same profile's server
   progress/favorites while keeping local and MDBList choices intact.
5. Navigate all four sign-ins on narrow iPhone layouts and with the TV remote.

## Official references

- [Seerr API](https://docs.seerr.dev/api/seerr-api/), `seerr-api.yml`, permission,
  authentication, service and media-type source at `seerr-team/seerr` revision
  `c57dca90f567eb659add041307555192cee23860`.
- [Silo API](https://siloserver.org/docs/api), native v2 OpenAPI and playback-v3
  contracts at [Silo Server](https://github.com/Silo-Server/silo-server) revision
  `6de6d5e5e285a9b423e95a1122cb39e5bb9ca93b`.
