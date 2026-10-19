import Foundation

enum LibraryMetadataSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case provider, tmdb, tvdb

    var id: String { rawValue }
    var title: String {
        switch self {
        case .provider: return "Provider"
        case .tmdb: return "TMDB"
        case .tvdb: return "TVDB"
        }
    }
    static let metadataKey = "Lineup.library.metadataSource.v1"
    static let episodesKey = "Lineup.library.episodeDataSource.v1"
}

/// Display data only. Server IDs, episode order, duration, and viewing state
/// always belong to the provider. This overlay is never encoded into its item.
struct LibraryMetadata: Codable, Hashable, Sendable {
    let source: LibraryMetadataSource
    let title: String
    var overview: String?
    var year: Int?
    var genres: [String]?
    var premiereDate: String?
    var poster: String?
    var backdrop: String?
    var externalIDs: [String: String] = [:]
    var attributionURL: String?
}

enum LibraryMetadataIdentity {
    struct Packed: Equatable, Sendable {
        let provider: String
        let value: String
        let season: Int?
        let episode: Int?
    }

    /// Only recognize AIOStreams' complete, versioned layout. An ordinary
    /// numeric library ID is never assumed to be a TMDB or TVDB identifier.
    static func packed(_ item: MediaItem) -> Packed? {
        let compact = item.id.replacingOccurrences(of: "-", with: "")
        guard compact.count == 32 else { return nil }
        let chars = Array(compact)
        var bytes: [UInt8] = []
        for offset in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(chars[offset...offset + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        let kind: UInt8
        switch item.type {
        case "Movie": kind = 1
        case "Series": kind = 2
        case "Episode": kind = 4
        default: return nil
        }
        guard bytes[0] == 0xA1, bytes[1] >> 4 == kind,
              bytes[2] == (kind == 1 ? 1 : 2), bytes[13...15].allSatisfy({ $0 == 0 }) else { return nil }
        let provider: String
        switch bytes[1] & 0xF {
        case 1: provider = "imdb"
        case 2: provider = "tmdb"
        case 3: provider = "tvdb"
        default: return nil
        }
        let number = bytes[3...8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard number > 0 else { return nil }
        let season = Int(bytes[9]) << 8 | Int(bytes[10])
        let episode = Int(bytes[11]) << 8 | Int(bytes[12])
        guard kind == 4 ? (season != 0xFFFF && episode != 0xFFFF)
            : (season == 0xFFFF && episode == 0xFFFF) else { return nil }
        let value = provider == "imdb" ? String(format: "tt%07llu", number) : String(number)
        return Packed(provider: provider, value: value,
                      season: kind == 4 ? season : nil, episode: kind == 4 ? episode : nil)
    }

    static func explicitID(_ value: String) -> (provider: String, value: String)? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.range(of: "^tt[0-9]{7,}$", options: .regularExpression) != nil,
           let id = positiveID("imdb", text) { return ("imdb", id) }
        for source in ["tmdb", "tvdb", "imdb"] {
            if text.range(of: "^" + source + "[:/\\-](tt)?[0-9]+$", options: .regularExpression) != nil,
               let id = positiveID(source, String(text.dropFirst(source.count + 1))) { return (source, id) }
        }
        return nil
    }

    static func ids(_ item: MediaItem) -> [String: String] {
        var result = MediaTitleMatch.providerIDs(of: item).filter { positiveID($0.key, $0.value) != nil }
        if item.type != "Episode", let packed = packed(item), result[packed.provider] == nil {
            result[packed.provider] = packed.value
        }
        for raw in [item.id, item.name] {
            if let explicit = explicitID(raw), result[explicit.provider] == nil {
                result[explicit.provider] = explicit.value
            }
        }
        return result
    }

    static func positiveID(_ provider: String, _ value: String) -> String? {
        guard let canonical = MediaTitleMatch.canonicalID(provider, value),
              let number = UInt64(provider == "imdb" ? String(canonical.dropFirst(2)) : canonical),
              number > 0 else { return nil }
        return canonical
    }

    static func searchableTitle(_ item: MediaItem) -> String? {
        let name = item.withMetadata(nil).name.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = name.range(of: "^[0-9]+$", options: .regularExpression) != nil
        let opaque = name.count >= 16 && name.range(of: "^[0-9a-fA-F\\-]+$", options: .regularExpression) != nil
        guard !name.isEmpty, explicitID(name) == nil, !numeric, !opaque,
              MediaTitleMatch.normalized(name).count > 1,
              !["unknown", "untitled", "movie", "series"].contains(name.lowercased()) else { return nil }
        return MediaTitleMatch.searchTerms(for: name).first ?? name
    }

    /// Prefer no match to a wrong remake or another show with the same name.
    static func uniqueMatch<T>(_ candidates: [T], item: MediaItem,
                               title: (T) -> String, year: (T) -> Int?) -> T? {
        guard let query = searchableTitle(item) else { return nil }
        let normalized = MediaTitleMatch.normalized(query)
        let exact = candidates.filter {
            MediaTitleMatch.normalized(title($0)) == normalized
                && (item.productionYear == nil || year($0) == item.productionYear)
        }
        return exact.count == 1 ? exact[0] : nil
    }

    static func requestKey(_ item: MediaItem, source: LibraryMetadataSource) -> String {
        let raw = item.withMetadata(nil)
        let ids = self.ids(raw).sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: ",")
        return [source.rawValue, raw.libraryKey, raw.type, raw.name, String(raw.productionYear ?? 0),
                ids, raw.seriesID ?? "", raw.seriesName ?? "", String(raw.parentIndexNumber ?? -1),
                String(raw.indexNumber ?? -1)].joined(separator: "|")
    }
}
