import Foundation

/// A title's scores as the sites themselves give them: IMDb and TMDB out of
/// ten, Rotten Tomatoes as a percentage.
struct MediaRatings: Codable, Equatable, Sendable {
    var imdb: Double?
    var tmdb: Double?
    var rottenTomatoes: Int?

    init(imdb: Double? = nil, tmdb: Double? = nil, rottenTomatoes: Int? = nil) {
        self.imdb = imdb
        self.tmdb = tmdb
        self.rottenTomatoes = rottenTomatoes
    }

    var isEmpty: Bool { imdb == nil && tmdb == nil && rottenTomatoes == nil }
    var isComplete: Bool { imdb != nil && tmdb != nil && rottenTomatoes != nil }

    /// These, with whatever they lack taken from `other`.
    func filling(from other: MediaRatings) -> MediaRatings {
        MediaRatings(imdb: imdb ?? other.imdb, tmdb: tmdb ?? other.tmdb,
                     rottenTomatoes: rottenTomatoes ?? other.rottenTomatoes)
    }

    /// From a server's per-source scores, which every addon stores out of a
    /// hundred: 80 from IMDb is an 8.0.
    init(metrics: [MediaMetric]) {
        self.init()
        for metric in metrics where metric.value > 0 {
            switch metric.source.lowercased() {
            case "imdb": imdb = Self.tenths(metric.value / 10)
            case "tmdb": tmdb = Self.tenths(metric.value / 10)
            case "rottentomatoes", "rotten_tomatoes", "tomatoes": rottenTomatoes = Self.percent(metric.value)
            default: break
            }
        }
    }

    /// What a title carries itself. A Jellyfin server's community rating is
    /// TMDB's unless its operator put another source first, and its critic
    /// rating is the Tomatometer; an IPTV provider's rating is TMDB's.
    init(item: MediaItem) {
        self.init(tmdb: item.communityRating.flatMap { $0 > 0 ? Self.outOfTen($0) : nil },
                  rottenTomatoes: item.criticRating.flatMap { $0 > 0 ? Self.percent($0) : nil })
    }

    /// From MDBList's `ratings`, a list of `{source, value, score}`. IMDb's
    /// value is out of ten; TMDB's and the Tomatometer's are out of a hundred,
    /// and so is every score, which stands in when a value is missing.
    init(mdbList raw: Any?) {
        self.init()
        guard let entries = raw as? [[String: Any]] else { return }
        for entry in entries {
            guard let source = (entry["source"] as? String)?.lowercased() else { continue }
            let value = Self.number(entry["value"]).flatMap { $0 > 0 ? $0 : nil }
            let score = Self.number(entry["score"]).flatMap { $0 > 0 ? $0 : nil }
            switch source {
            case "imdb":
                if let value { imdb = Self.outOfTen(value) } else if let score { imdb = Self.tenths(score / 10) }
            case "tmdb":
                if let score { tmdb = Self.tenths(score / 10) } else if let value { tmdb = Self.outOfTen(value) }
            case "tomatoes", "rottentomatoes":
                if let found = value ?? score { rottenTomatoes = Self.percent(found) }
            default:
                break
            }
        }
    }

    /// A score out of ten, from one that may have been written out of a
    /// hundred instead.
    static func outOfTen(_ value: Double) -> Double {
        tenths(value > 10 ? value / 10 : value)
    }

    private static func tenths(_ value: Double) -> Double {
        (min(max(value, 0), 10) * 10).rounded() / 10
    }

    static func percent(_ value: Double) -> Int {
        Int(min(max(value, 0), 100).rounded())
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
