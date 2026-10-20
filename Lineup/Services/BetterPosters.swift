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
    /// Fanart.tv's title logo for a movie or show, once its IDs are known:
    /// nil while Title Logos is off, without a key, or where it has none.
    func fanartLogo(for item: MediaItem) async -> URL? {
        guard fanartEnabled, MobileFanart.configured, ["Movie", "Series"].contains(item.type) else { return nil }
        await resolveMetadata(for: item)
        guard !Task.isCancelled else { return nil }
        var matched = displayItem(item)
        if MobileFanartIdentity(item: matched) == nil {
            matched = await libraryExternalIdentity(item, requiring: item.isSeries ? "tvdb" : "imdb")
        }
        guard !Task.isCancelled, let identity = MobileFanartIdentity(item: matched) else { return nil }
        return await MobileFanart.shared.logo(for: identity)
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
