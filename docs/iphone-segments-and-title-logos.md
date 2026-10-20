# iPhone playback segments and title logos

## IntroDB

Library playback requests the public IntroDB /segments endpoint once per exact
episode or movie identity. Episodes use the show's IMDb ID and original
season/episode numbers, including supported packed AIOStreams IDs. Movies use
their IMDb ID and is_movie=true without episode query parameters. Live movie
responses currently return zero season/episode coordinates; omitted/null and
zero coordinates are accepted for movies only.

The existing Skip Intro behavior now shares its request with Skip Recap and
end-credit data. A segment requires an exact reply identity, finite nonnegative
timestamps, a supported length, at least one submission and confidence >=0.8.
Malformed new fields cannot discard a valid intro. Community no-segment flags
take precedence, and overlapping recaps are rejected. Skip controls only appear
inside their intervals and use the existing manual seek path.

Lineup still chooses the next episode through MediaLibrary.episodeAfter, builds
the same MobileNextEpisodeOffer, and uses the same Play Now/Not Now actions and
source selection. IntroDB does not supply an episode queue or replace the card.
A matching outro can show that existing card during credits. Without usable
data, or with the setting off, its original final-30-seconds timing remains.
The prompt stays hidden during loading, errors, scrubbing, PiP and live playback.
There is no automatic episode jump, countdown or watched-state update from
receiving timestamps. Playback progress and natural completion retain their
existing reporting paths.

Movies with both usable credits and a later post-credit scene show a small
noninteractive notice during credits. It disappears when the scene begins.

The IntroDB client and segment model live in Lineup/Services and are shared by
both apps. The Apple TV Library player offers the same Skip Intro and Skip
Recap prompts, the same credits timing for Next Episode and the same
post-credits notice, under the same four settings.
Missing scene data never promises a scene. No automatic credits skip or seek is
introduced. Timestamp coverage and cut-specific accuracy depend on community
data; matching IMDb identity does not guarantee every release has the same edit.

Skip Intro, Skip Recap, Next Episode During Credits and Post-Credit Scene Notices
have independent accent-colored Settings > Metadata toggles, enabled by default.
Requests load alongside playback, have a five-second timeout, coalesce and cache
up to256 identities, including misses. Existing service backoff remains.
Sports/Guide previews and replay playback do not request Library segment data.

## Fanart.tv

The iPhone Library hero and movie/show detail titles can use transparent title
logos from the official Fanart.tv v3.2 API. Movies use canonical TMDB or IMDb IDs;
shows use canonical TVDB IDs. Server-local numeric IDs are never substituted.
Missing TVDB identities can use the existing metadata resolver independently of
the viewer's display-source preference.

The API response must repeat the requested identity. Logo selection prefers
English, then neutral-language images, HD before standard at the same language,
and higher likes within those groups. Only official HTTPS public bitmap asset
URLs are passed to the existing off-main artwork loader and image cache.
Posters, episode stills, backdrops, hero fades, zoom and four-second rotation keep
their existing sources. Text remains visible until a logo loads, with reserved
geometry to prevent a late image shifting the surrounding content. Reduce
Motion disables the short appearance fade. VoiceOver reads the title text.

Only visible title lockups request logos. Per-identity API tasks coalesce, API
connections are limited to two per host, response caches are bounded to256
identities, missing images are cached, and service errors/rate limits back off.
API redirects are refused; the asset loader never receives the API key.
Settings > Metadata > Title Logos controls the integration and credits Fanart.tv.

Use the project key from https://fanart.tv/get-an-api-key/ as the Actions secret
LINEUP_FANART_API_KEY. Testers do not enter keys. It is injected into the ignored
LineupMetadata.json resource, never committed or logged. Like the app's existing
consumer credentials, a bundled project key can be extracted from an installed
app. Do not use an account credential. No personal client_key or VIP purchase is
required for the implemented API route.

Both builds' configuration checks require the key before dependency
resolution and again in the packaged app. The service and its policy are
shared (`Lineup/Services/Fanart.swift`, `FanartPolicy.swift`), as is the
lookup, `MediaLibrary.fanartLogo(for:)`. The Apple TV draws a Fanart logo in
its Library preview and title page where the server has no logo of its own;
Settings › Metadata › Title Logos switches it, as on the phone.

## Validation

Local source membership5, bundle configuration9, service packaging4, tvOS focus,
workflow lint and diff checks pass. Public live IntroDB episode and movie calls
confirmed the current segment response shape, including movie zero coordinates.

New Foundation preflights compile the production segment and Fanart policies
and exercise identity isolation, manual segment boundaries, credits fallback,
runtime mismatch, post-credit safety, language/quality selection and asset URLs.
Five new Apple SDK tests cover actual URLSession request/coalescing/cache,
movie query semantics, service backoff and independently persisted settings.
Existing IntroDB, tracking, playback and source-selection coverage stays enabled.

The supplied Fanart.tv project key authenticated real v3.2 TMDB movie, IMDb
movie and TVDB show requests with exact returned IDs. Selected English/neutral
title-logo assets downloaded successfully as public PNGs (800x310). The key is
stored in the repository Actions secret. Tools/verify-fanart.py repeats those
checks without printing credentials or credentialed URLs.

There is no local Swift/Apple SDK. New Swift checks, full simulator tests and
device behavior are PENDING the iPhone126 CI run. No success is assumed from
the API checks.

References: https://introdb.app/docs/api,
https://introdb.app/docs/movies,
https://github.com/fanart-tv/fanart.tv-api.
