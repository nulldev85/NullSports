import Foundation

struct LibraryPlaybackSample: Equatable, Sendable {
    let playing: Bool
    let pictureInPicture: Bool
    let position: TimeInterval
    let duration: TimeInterval
    func differs(from previous: Self?) -> Bool {
        guard let previous else { return true }
        return playing != previous.playing || pictureInPicture != previous.pictureInPicture
            || abs(position - previous.position) >= 5 || abs(duration - previous.duration) >= 1
    }
}

enum LibraryTrackingPreferences {
    static let localKey = "Lineup.tracking.local.v1"
    static let mdbKey = "Lineup.tracking.mdblist.v1"
    static let accountKey = "Lineup.tracking.mdblistAccount.v1"
    static func cacheKey(_ account: Int) -> String { "Lineup.tracking.mdblistPlayback.v1.\(account)" }
}

struct MDBListTrackingTarget: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case movie, episode, show }
    let kind: Kind
    let ids: [String: String]
    var season: Int? = nil
    var episode: Int? = nil
    var episodeIDs: [String: String] = [:]
    var tvdbSeason: Int? = nil
    var tvdbEpisode: Int? = nil
    var tvdbSeries: String? = nil

    var key: String {
        [kind.rawValue, ids["tmdb"].map { "tmdb:\($0)" } ?? ids["imdb"].map { "imdb:\($0)" }
            ?? ids["tvdb"].map { "tvdb:\($0)" } ?? "", String(season ?? -1), String(episode ?? -1)].joined(separator: "|")
    }
    var valid: Bool {
        guard Self.normalizedIDs(ids) == ids else { return false }
        let identity = kind == .movie ? ids["imdb"] != nil || ids["tmdb"] != nil : !ids.isEmpty
        return identity && (kind != .episode || (season.map { $0 >= 0 } == true && episode.map { $0 > 0 } == true))
    }
    static func normalizedIDs(_ raw: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in raw {
            let name = name.lowercased(), value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "imdb", value.range(of: "^tt[0-9]+$", options: .regularExpression) != nil { result[name] = value }
            if ["tmdb", "tvdb"].contains(name), let number = Int(value), number > 0 { result[name] = String(number) }
        }
        return result
    }
    var wireIDs: [String: Any] { ids.mapValues { Int($0).map { $0 as Any } ?? ($0 as Any) } }
    var scrobbleBody: [String: Any] {
        if kind == .movie { return ["movie": ["ids": wireIDs]] }
        return ["show": ["ids": wireIDs, "season": season ?? 0, "episode": episode ?? 0]]
    }
    func watchedBody(at date: Date) -> [String: Any] {
        let time = ISO8601DateFormatter().string(from: date)
        if kind == .movie { return ["movies": [["ids": wireIDs, "watched_at": time]]] }
        if kind == .show { return ["shows": [["ids": wireIDs, "watched_at": time]]] }
        if !episodeIDs.isEmpty {
            return ["episodes": [["ids": episodeIDs.mapValues { Int($0).map { $0 as Any } ?? ($0 as Any) }, "watched_at": time]]]
        }
        return ["shows": [["ids": wireIDs, "seasons": [["number": season ?? 0,
            "episodes": [["number": episode ?? 0, "watched_at": time]]]]]]]
    }
}

struct MDBListTrackingWrite: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case start, pause, stop, watched, unwatched, clear }
    let id: UUID
    let sessionID: UUID?
    let target: MDBListTrackingTarget
    let action: Action
    let progress: Double
    let occurredAt: Date
    var path: String {
        switch action {
        case .watched: "sync/watched"
        case .unwatched: "sync/watched/remove"
        default: "scrobble/\(action.rawValue)"
        }
    }
    var body: [String: Any] {
        if action == .watched || action == .unwatched { return target.watchedBody(at: occurredAt) }
        var value = target.scrobbleBody
        value["progress"] = min(100, max(0, progress))
        value["app_name"] = "Lineup"
        value["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.19.0"
        return value
    }
}

struct MDBListTrackingRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case watched, progress, upNext }
    let target: MDBListTrackingTarget
    let state: State
    let progress: Double
    let updatedAt: Date
    var runtime: Double = 0
}

enum MDBListTrackingFailure: Error {
    case invalidResponse, credentials, rateLimited(Date), unavailable, network
}
