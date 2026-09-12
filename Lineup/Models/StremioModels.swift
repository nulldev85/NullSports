import Foundation

// A Stremio addon is four JSON endpoints behind one base URL:
//
//   {base}/manifest.json                  what it is and what it offers
//   {base}/catalog/{type}/{id}.json       a row of things
//   {base}/meta/{type}/{id}.json          one thing in full
//   {base}/stream/{type}/{id}.json        where to play it from
//
// The protocol is small and stable, which is the whole appeal: talking to an
// addon directly means a catalogue is a request away rather than something a
// server has to be told to import first.
//
// The types below are deliberately forgiving. Addons are written by many
// different people and the manifests in the wild disagree with each other on
// several points that the specification left open, so each of those is handled
// where it appears rather than assumed away.

/// One element of a list, kept only if it could be read.
///
/// A catalog of a hundred films that contains one entry an addon got wrong
/// decodes, as a plain array, to nothing at all -- the whole row is lost to the
/// one bad item. Wrapping each element means a failure costs that element and
/// nothing else, and because this decoder never throws, the list always
/// advances past it cleanly.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension Array {
    /// The readable elements of a list, or an empty list if the key is missing.
    static func lossy<Key: CodingKey>(_ box: KeyedDecodingContainer<Key>,
                                      _ key: Key) -> [Element] where Element: Decodable {
        ((try? box.decode([Lossy<Element>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

/// What an addon says it is, from `manifest.json`.
struct StremioManifest: Decodable, Sendable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let logo: String?
    /// Declared as plain strings by most addons and as objects by some, which
    /// is the first place a strict decoder falls over.
    let resources: [String]
    let types: [String]
    let catalogs: [StremioCatalogSpec]

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, resources, types, catalogs
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        name = try box.decode(String.self, forKey: .name)
        version = try? box.decode(String.self, forKey: .version)
        description = try? box.decode(String.self, forKey: .description)
        logo = try? box.decode(String.self, forKey: .logo)
        types = (try? box.decode([String].self, forKey: .types)) ?? []
        catalogs = .lossy(box, .catalogs)
        resources = [StremioResource].lossy(box, .resources).map(\.name)
    }

    /// An addon that declares catalogs serves catalogs. The `resources` list is
    /// the stricter test and several addons in the wild leave "catalog" out of
    /// it while offering half a dozen, so the catalogs themselves are the
    /// answer -- a catalog that then refuses a request says so on its own.
    var providesCatalogs: Bool { !catalogs.isEmpty }
    var providesStreams: Bool { resources.contains("stream") }
    var providesMeta: Bool { resources.contains("meta") }
}

/// One entry of a manifest's `resources`, which is a string in most addons and
/// an object with the name inside in the rest. Both mean the same thing.
private struct StremioResource: Decodable {
    let name: String

    init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            name = plain
            return
        }
        struct Object: Decodable { let name: String }
        name = try Object(from: decoder).name
    }
}

/// A row an addon offers.
struct StremioCatalogSpec: Codable, Identifiable, Hashable, Sendable {
    let type: String
    let id: String
    let name: String?
    /// Named parameters this catalogue accepts. Current addons declare these as
    /// objects under `extra`; older ones list names under `extraSupported`.
    let extra: [String]
    let required: [String]

    var title: String { name ?? id.capitalized }
    /// A catalogue that cannot be listed without a search term is not a row;
    /// it is a search box, and asking it for a row returns an error.
    var isBrowsable: Bool { !required.contains("search") }

    enum CodingKeys: String, CodingKey {
        case type, id, name, extra, extraSupported, extraRequired
    }

    private struct Extra: Decodable {
        let name: String
        let isRequired: Bool?
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        type = try box.decode(String.self, forKey: .type)
        id = try box.decode(String.self, forKey: .id)
        name = try? box.decode(String.self, forKey: .name)
        if let objects = try? box.decode([Extra].self, forKey: .extra) {
            extra = objects.map(\.name)
            required = objects.filter { $0.isRequired == true }.map(\.name)
        } else {
            extra = (try? box.decode([String].self, forKey: .extraSupported)) ?? []
            required = (try? box.decode([String].self, forKey: .extraRequired)) ?? []
        }
    }

    /// Written back in the older of the two spellings, which is the one whose
    /// two lists map straight onto the two properties kept here. The reader
    /// above accepts it, so a stored addon reads back as the addon it was.
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(type, forKey: .type)
        try box.encode(id, forKey: .id)
        try box.encodeIfPresent(name, forKey: .name)
        try box.encode(extra, forKey: .extraSupported)
        try box.encode(required, forKey: .extraRequired)
    }
}

/// `{ "metas": [...] }`, the response to a catalogue request.
struct StremioCatalogResponse: Decodable, Sendable {
    let metas: [StremioMeta]

    enum CodingKeys: String, CodingKey { case metas }

    init(from decoder: Decoder) throws {
        metas = .lossy(try decoder.container(keyedBy: CodingKeys.self), .metas)
    }
}

/// `{ "meta": {...} }`, the response to a meta request.
struct StremioMetaResponse: Decodable, Sendable {
    let meta: StremioMeta
}

/// One film, series or episode, as an addon describes it.
struct StremioMeta: Decodable, Sendable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let description: String?
    /// A year, a range, or an open range: "2019", "2019-2024", "2019-".
    let releaseInfo: String?
    let genres: [String]?
    let imdbRating: String?
    let runtime: String?
    /// Series only: the episodes, which an addon may call either of two things.
    let videos: [StremioVideo]?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, description
        case releaseInfo, genres, genre, imdbRating, runtime, videos
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        type = (try? box.decode(String.self, forKey: .type)) ?? "movie"
        name = (try? box.decode(String.self, forKey: .name)) ?? "Untitled"
        poster = try? box.decode(String.self, forKey: .poster)
        background = try? box.decode(String.self, forKey: .background)
        description = try? box.decode(String.self, forKey: .description)
        releaseInfo = try? box.decode(String.self, forKey: .releaseInfo)
        // Some addons send a single genre string where the rest send a list.
        if let list = try? box.decode([String].self, forKey: .genres) {
            genres = list
        } else if let list = try? box.decode([String].self, forKey: .genre) {
            genres = list
        } else if let one = try? box.decode(String.self, forKey: .genre) {
            genres = [one]
        } else {
            genres = nil
        }
        // The rating arrives as a string from most and a number from some.
        if let text = try? box.decode(String.self, forKey: .imdbRating) {
            imdbRating = text
        } else if let number = try? box.decode(Double.self, forKey: .imdbRating) {
            imdbRating = String(number)
        } else {
            imdbRating = nil
        }
        runtime = try? box.decode(String.self, forKey: .runtime)
        let episodes: [StremioVideo] = .lossy(box, .videos)
        videos = episodes.isEmpty ? nil : episodes
    }

    /// The first four digits of the release info, which is the year whether it
    /// was given alone or at the head of a range.
    var year: Int? {
        guard let releaseInfo else { return nil }
        let digits = releaseInfo.prefix { $0.isNumber }
        return digits.count == 4 ? Int(digits) : nil
    }
}

/// An episode of a series.
struct StremioVideo: Decodable, Sendable {
    let id: String
    let title: String?
    let season: Int?
    let episode: Int?
    let released: String?
    let overview: String?
    let thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, season, episode, number, released, overview, description, thumbnail
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        title = (try? box.decode(String.self, forKey: .title))
            ?? (try? box.decode(String.self, forKey: .name))
        season = try? box.decode(Int.self, forKey: .season)
        episode = (try? box.decode(Int.self, forKey: .episode))
            ?? (try? box.decode(Int.self, forKey: .number))
        released = try? box.decode(String.self, forKey: .released)
        overview = (try? box.decode(String.self, forKey: .overview))
            ?? (try? box.decode(String.self, forKey: .description))
        thumbnail = try? box.decode(String.self, forKey: .thumbnail)
    }
}

/// `{ "streams": [...] }`, the response to a stream request.
struct StremioStreamResponse: Decodable, Sendable {
    let streams: [StremioStream]

    enum CodingKeys: String, CodingKey { case streams }

    init(from decoder: Decoder) throws {
        streams = .lossy(try decoder.container(keyedBy: CodingKeys.self), .streams)
    }
}

/// One way to watch something.
///
/// Only a stream carrying a `url` can be played here. An addon may instead
/// return an `infoHash`, which is a torrent and needs an engine this app does
/// not have, or a `ytId`, or an `externalUrl` meaning "open this somewhere
/// else". Those are counted and reported rather than silently dropped, because
/// a popular addon returning nothing but torrents is a thing worth being told.
struct StremioStream: Decodable, Sendable {
    let url: String?
    let name: String?
    let title: String?
    let description: String?
    let infoHash: String?
    let ytId: String?
    let externalUrl: String?
    let behaviorHints: BehaviorHints?

    struct BehaviorHints: Decodable, Sendable {
        let bingeGroup: String?
        let filename: String?
        let videoSize: Int64?
    }

    var isPlayable: Bool { url != nil }

    /// What the addon calls this stream. Addons put the readable part in
    /// `title` or `description` and the source's own name in `name`, and they
    /// are not consistent about which.
    var label: String {
        let body = title ?? description ?? behaviorHints?.filename ?? "Stream"
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - An installed addon

/// An addon the viewer has added, as Lineup keeps it.
///
/// The manifest is read once, when the addon is added, and what matters from it
/// is kept here: a screen asking "what rows can I offer" should not cost a
/// round trip to every addon each time it opens.
struct StremioAddon: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    /// The base the four endpoints hang off, already normalised.
    var address: String
    var logo: String?
    var types: [String]
    /// Only the catalogs that can actually be listed as a row.
    var catalogs: [StremioCatalogSpec]
    var providesStreams: Bool
    var providesMeta: Bool

    init(manifest: StremioManifest, address: String) {
        id = manifest.id
        name = manifest.name
        self.address = address
        logo = manifest.logo
        types = manifest.types
        catalogs = manifest.catalogs.filter(\.isBrowsable)
        providesStreams = manifest.providesStreams
        providesMeta = manifest.providesMeta
    }

    /// Whether this addon is worth asking about a stream for this kind of
    /// thing. An addon that declares no types at all is asked anyway: several
    /// of the widely used ones leave the list off and answer for everything.
    func streams(for type: String) -> Bool {
        providesStreams && (types.isEmpty || types.contains(type))
    }

    /// The catalogs that take a search term, which is a different question
    /// from the rows this addon offers.
    var searchable: [StremioCatalogSpec] {
        catalogs.filter { $0.extra.contains("search") }
    }
}

/// How an addon's things are named once they are inside Lineup.
///
/// Every id here carries the addon it came from, because two addons naming the
/// same film is the normal case rather than a clash to be avoided -- and a row,
/// a card and a stream request all need to know which addon to go back to.
enum StremioID {
    static func shelf(addon: String, catalog: StremioCatalogSpec) -> String {
        "addon:\(addon)|catalog|\(catalog.type)|\(catalog.id)"
    }

    static func item(addon: String, type: String, id: String) -> String {
        "addon:\(addon)|\(type)|\(id)"
    }

    static func season(addon: String, series: String, number: Int) -> String {
        "addon:\(addon)|season|\(series)|\(number)"
    }
}

// MARK: - Becoming a MediaItem

/// An addon's things, in the shape the rest of the app already understands.
///
/// Nothing downstream of here knows what Stremio is. A shelf, a card, a show
/// page and the stream picker were all written against `MediaItem`, and an
/// addon's answers are turned into exactly that -- so the addon feature is a
/// source of items rather than a second copy of the screens that show them.
extension MediaItem {
    /// Jellyfin's word for what an addon calls `type`. The app's own rules --
    /// what is playable, what opens a show page -- read this field, so an
    /// addon's series has to arrive as a series rather than as a "series".
    static func kind(forStremio type: String) -> String {
        switch type.lowercased() {
        case "movie": return "Movie"
        case "series": return "Series"
        default: return "Video"
        }
    }

    init(meta: StremioMeta, addonID: String) {
        self.init(
            id: StremioID.item(addon: addonID, type: meta.type, id: meta.id),
            name: meta.name,
            type: MediaItem.kind(forStremio: meta.type),
            overview: meta.description,
            productionYear: meta.year,
            primaryImageAspectRatio: nil,
            childCount: meta.videos?.isEmpty == false ? meta.videos?.count : nil,
            genres: meta.genres,
            communityRating: meta.imdbRating.flatMap { Double($0) },
            runTimeTicks: MediaItem.ticks(fromRuntime: meta.runtime),
            addonID: addonID,
            stremioType: meta.type,
            stremioID: meta.id,
            posterURL: meta.poster,
            backdropURL: meta.background
        )
    }

    /// One episode of a series.
    ///
    /// The id a stream is asked for is the episode's own, and the protocol
    /// spells it `{series}:{season}:{episode}`. Most addons already return it
    /// that way; the ones that do not have it built here, because a bare id
    /// would fetch the whole series' streams instead of this episode's.
    init(video: StremioVideo, in meta: StremioMeta, addonID: String) {
        let composed: String
        if video.id.contains(":") {
            composed = video.id
        } else if let season = video.season, let episode = video.episode {
            composed = "\(meta.id):\(season):\(episode)"
        } else {
            composed = video.id
        }
        self.init(
            id: StremioID.item(addon: addonID, type: "episode", id: composed),
            name: video.title ?? "Episode \(video.episode ?? 0)",
            type: "Episode",
            overview: video.overview,
            productionYear: nil,
            primaryImageAspectRatio: nil,
            childCount: nil,
            premiereDate: video.released,
            indexNumber: video.episode,
            parentIndexNumber: video.season,
            seriesName: meta.name,
            addonID: addonID,
            // An episode's streams are asked for under the series type, not an
            // "episode" one: the protocol has no such type.
            stremioType: meta.type,
            stremioID: composed,
            posterURL: video.thumbnail ?? meta.poster,
            backdropURL: meta.background
        )
    }

    /// A season of a series. Addons hang every episode off the series in one
    /// flat list, so the seasons are read back out of it rather than fetched.
    init(season number: Int, of meta: StremioMeta, addonID: String, episodes: Int) {
        self.init(
            id: StremioID.season(addon: addonID, series: meta.id, number: number),
            name: number == 0 ? "Specials" : "Season \(number)",
            type: "Season",
            overview: nil,
            productionYear: nil,
            primaryImageAspectRatio: nil,
            childCount: episodes,
            indexNumber: number,
            seriesName: meta.name,
            addonID: addonID,
            stremioType: meta.type,
            stremioID: meta.id,
            posterURL: meta.poster,
            backdropURL: meta.background
        )
    }

    /// The row itself: a catalog, standing in for the folder a server would
    /// have had. It is never browsed into by id -- the addon is asked again --
    /// but it carries the addon and the catalog so that asking is possible.
    init(catalog: StremioCatalogSpec, addon: StremioAddon) {
        self.init(
            id: StremioID.shelf(addon: addon.id, catalog: catalog),
            name: catalog.title,
            type: "CollectionFolder",
            overview: nil,
            productionYear: nil,
            primaryImageAspectRatio: nil,
            childCount: nil,
            addonID: addon.id,
            stremioType: catalog.type,
            stremioID: catalog.id
        )
    }

    /// "142 min" in the units a server would have reported it in.
    static func ticks(fromRuntime runtime: String?) -> Int64? {
        guard let runtime else { return nil }
        let digits = runtime.prefix { $0.isNumber }
        guard let minutes = Int64(digits), minutes > 0 else { return nil }
        return minutes * 600_000_000
    }
}

// MARK: - Becoming a playback source

/// A stream, in the shape the stream picker already reads.
///
/// `MediaPlaybackSource` grew around a Nullfin server's answers, and everything
/// it works out -- the quality, the codecs, the release name, which addon a
/// result came from -- it works out by reading those same few text fields. An
/// addon's stream carries the same facts in the same kind of text, so it is
/// filled in rather than described a second way.
extension MediaPlaybackSource {
    init(stream: StremioStream, addon: StremioAddon, index: Int) {
        let filename = stream.behaviorHints?.filename
        let text = [stream.name, stream.title, stream.description]
            .compactMap { $0 }.joined(separator: "\n")
        self.init(
            id: "\(addon.id)|\(index)",
            name: text.isEmpty ? stream.label : text,
            // The picker plays whatever is in `path`, which for a server was a
            // file on disk and for an addon is the stream's own address.
            path: stream.url,
            container: MediaPlaybackSource.container(ofFile: filename),
            size: stream.behaviorHints?.videoSize,
            bitrate: nil,
            remux: RemuxInfo(providerInfo: ProviderInfo(
                source: addon.name,
                filename: filename ?? stream.label,
                description: stream.description
            ))
        )
    }

    private static func container(ofFile name: String?) -> String? {
        guard let name, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let extensionText = name[name.index(after: dot)...].lowercased()
        guard (2...4).contains(extensionText.count),
              extensionText.allSatisfy(\.isLetter) else { return nil }
        return extensionText
    }
}
