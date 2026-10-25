import Foundation

enum MobileBetterPosters {
    static let defaultTemplate = "https://btttr.cc/poster/imdb/poster-default/{imdb_id}.jpg"

    /// Accept only the image pattern produced by the official configurator.
    /// Never accept manifests, third-party proxies, or credentials in a URL.
    static func validTemplate(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 1024, text.components(separatedBy: "{imdb_id}").count == 2,
              let url = URLComponents(string: text.replacingOccurrences(of: "{imdb_id}", with: "tt0903747")),
              url.scheme == "https", url.host?.lowercased() == "btttr.cc",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              url.path.range(of: "^/poster(-[gnrqa]+)?/imdb/poster-default/tt0903747\\.jpg$",
                             options: .regularExpression) != nil else { return false }
        let allowed: Set<String> = ["tag", "lang", "rs"]
        return (url.queryItems ?? []).allSatisfy { allowed.contains($0.name) && !($0.value ?? "").isEmpty }
    }

    static func url(for item: MediaItem, template: String) -> URL? {
        guard ["Movie", "Series"].contains(item.type), validTemplate(template),
              let imdb = LibraryMetadataIdentity.ids(item)["imdb"],
              imdb.range(of: "^tt[0-9]{7,}$", options: .regularExpression) != nil else { return nil }
        return URL(string: template.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{imdb_id}", with: imdb))
    }
}

extension MediaLibrary {
    func betterPosterURL(for item: MediaItem) -> URL? {
        guard betterPostersEnabled else { return nil }
        let item = displayItem(item)
        if let url = MobileBetterPosters.url(for: item, template: betterPostersTemplate) { return url }
        guard let imdb = betterPosterIDs[item.libraryKey] else { return nil }
        let identity = item.withMetadata(LibraryMetadata(source: .provider, title: item.name, externalIDs: ["imdb": imdb]))
        return MobileBetterPosters.url(for: identity, template: betterPostersTemplate)
    }

    func resolveBetterPosterIdentity(for item: MediaItem) async {
        guard betterPostersEnabled, ["Movie", "Series"].contains(item.type),
              LibraryMetadataIdentity.ids(displayItem(item))["imdb"] == nil,
              betterPosterIDs[item.libraryKey] == nil else { return }
        await resolveMetadata(for: item)
        guard !Task.isCancelled, LibraryMetadataIdentity.ids(displayItem(item))["imdb"] == nil else { return }
        let matched = await libraryExternalIdentity(item)
        guard !Task.isCancelled, let imdb = LibraryMetadataIdentity.ids(matched)["imdb"] else { return }
        betterPosterIDs[item.libraryKey] = imdb
    }
}

extension MediaLibrary {
    /// Visible title art does not wait for full cast/overview/ratings metadata.
    /// Resolve only a missing external identity required by Fanart's namespace.
    func fastFanartLogo(for item: MediaItem) async -> URL? {
        guard fanartEnabled, MobileFanart.configured, ["Movie", "Series"].contains(item.type) else { return nil }
        var matched = displayItem(item)
        if MobileFanartIdentity(item: matched) == nil {
            matched = await libraryExternalIdentity(item, requiring: item.isSeries ? "tvdb" : "imdb")
        }
        guard !Task.isCancelled, let identity = MobileFanartIdentity(item: matched) else { return nil }
        return await MobileFanart.shared.logo(for: identity)
    }

    func warmTitleLogos(for item: MediaItem) async {
        let enabled = fanartEnabled
        let key = LineupTitleArtwork.cacheKey(for: item, catalogEnabled: enabled)
        let artwork = LineupTitleArtwork()
        await artwork.load(key: key, pixels: LineupTitleArtwork.pixels, server: logoURL(for: item), cacheKey: key,
            fanart: { enabled ? await self.fastFanartLogo(for: item) : nil },
            tmdb: { enabled ? await self.tmdbTitleLogo(for: item) : nil })
    }

    /// A server logo remains first choice. For title artwork, Fanart.tv is
    /// preferred, then TMDB's matching logo artwork, with the title text as
    /// the final fallback when neither catalog has a usable asset.
    func titleLogo(for item: MediaItem) async -> URL? {
        guard fanartEnabled, ["Movie", "Series"].contains(item.type) else { return nil }
        await resolveMetadata(for: item)
        guard !Task.isCancelled else { return nil }
        var matched = displayItem(item)
        if MobileFanartIdentity(item: matched) == nil {
            matched = await libraryExternalIdentity(item, requiring: item.isSeries ? "tvdb" : "imdb")
        }
        guard !Task.isCancelled else { return nil }
        if MobileFanart.configured, let identity = MobileFanartIdentity(item: matched),
           let logo = await MobileFanart.shared.logo(for: identity) {
            return logo
        }
        guard !Task.isCancelled else { return nil }
        return await tmdbTitleLogo(for: matched)
    }
}

extension MobileFanartIdentity {
    /// The ID Fanart.tv files a title under: a show's TVDB, a film's TMDB,
    /// else its IMDb.
    init?(item: MediaItem) {
        let ids = LibraryMetadataIdentity.ids(item)
        if item.type == "Series", let tvdb = ids["tvdb"] {
            self.init(kind: .series, id: tvdb)
            return
        }
        guard item.type == "Movie" else { return nil }
        for provider in ["tmdb", "imdb"] {
            if let id = ids[provider], let identity = MobileFanartIdentity(kind: .movie, id: id) {
                self = identity
                return
            }
        }
        return nil
    }
}
