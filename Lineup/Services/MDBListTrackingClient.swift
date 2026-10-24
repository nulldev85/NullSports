import Foundation

/// Personal-account operations. No account writes occur until tracking is enabled.
struct MDBListTrackingClient: Sendable {
    let apiKey: String
    var session: URLSession = .shared

    func write(_ event: MDBListTrackingWrite) async throws {
        let response = try await request(event.path, body: event.body)
        guard let object = response as? [String: Any] else { throw MDBListTrackingFailure.invalidResponse }
        for key in ["errors", "not_found"] {
            if let values = object[key] as? [Any], !values.isEmpty { throw MDBListTrackingFailure.unavailable }
            if let values = object[key] as? [String: Any], values.values.contains(where: {
                if let array = $0 as? [Any] { return !array.isEmpty }; return false
            }) { throw MDBListTrackingFailure.unavailable }
        }
        if object["error"] != nil { throw MDBListTrackingFailure.unavailable }
        switch event.action {
        case .watched:
            guard object["updated"] is [String: Any] || object["history_only"] is [String: Any] else {
                throw MDBListTrackingFailure.invalidResponse
            }
        case .unwatched:
            guard object["deleted"] is [String: Any] else { throw MDBListTrackingFailure.invalidResponse }
        default:
            guard let action = object["action"] as? String, !action.isEmpty else { throw MDBListTrackingFailure.invalidResponse }
        }
    }

    func snapshot() async throws -> [MDBListTrackingRecord] {
        var records: [MDBListTrackingRecord] = []
        // Fetch complete positive-state buckets. Only a fully successful snapshot
        // is published, so an outage or missing page never becomes a mass removal.
        for kind in ["movie", "episode"] {
            var cursor: String?
            var visited: Set<String> = []
            repeat {
                var query = [URLQueryItem(name: "mediatype", value: kind), URLQueryItem(name: "limit", value: "1000"),
                             URLQueryItem(name: "append_to_response", value: "tvdb")]
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                let value = try await request("sync/watched", query: query)
                guard let object = value as? [String: Any],
                      let rows = object[kind == "movie" ? "movies" : "episodes"] as? [[String: Any]] else {
                    throw MDBListTrackingFailure.invalidResponse
                }
                // A malformed page must not turn saved watched entries into
                // removals. Unknown/expired playback entries are handled below.
                let bucket = [kind == "movie" ? "movies" : "episodes": rows]
                guard Self.history(bucket).count == rows.count else { throw MDBListTrackingFailure.invalidResponse }
                records += Self.history(bucket)
                cursor = (object["pagination"] as? [String: Any])?["next_cursor"] as? String
                if let next = cursor, next.isEmpty { cursor = nil }
                if let cursor, (!visited.insert(cursor).inserted || visited.count > 100) {
                    throw MDBListTrackingFailure.invalidResponse
                }
            } while cursor != nil
        }
        guard let playback = try await request("sync/playback") as? [[String: Any]] else {
            throw MDBListTrackingFailure.invalidResponse
        }
        records += Self.playback(playback)
        var offset = 0
        while true {
            guard let object = try await request("upnext", query: [URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "hide_unreleased", value: "true")]) as? [String: Any],
                  let items = object["items"] as? [[String: Any]] else { throw MDBListTrackingFailure.invalidResponse }
            records += Self.upNext(items)
            guard items.count == 100 else { break }
            offset += 100
            guard offset < 10_000 else { throw MDBListTrackingFailure.invalidResponse }
        }
        return records
    }

    private func request(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Any {
        guard !apiKey.isEmpty else { throw MDBListTrackingFailure.credentials }
        var url = URLComponents(string: "https://api.mdblist.com/\(path)")!
        url.queryItems = query + [URLQueryItem(name: "apikey", value: apiKey)]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MDBListTrackingFailure.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw MDBListTrackingFailure.credentials }
        if response.statusCode == 429 {
            let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
            throw MDBListTrackingFailure.rateLimited(Date().addingTimeInterval(max(1, seconds)))
        }
        guard (200..<300).contains(response.statusCode) else {
            if (400..<500).contains(response.statusCode) { throw MDBListTrackingFailure.unavailable }
            throw MDBListTrackingFailure.network
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw MDBListTrackingFailure.invalidResponse }
        return value
    }

    static func ids(_ object: [String: Any]?) -> [String: String] {
        guard let raw = object?["ids"] as? [String: Any] else { return [:] }
        return MDBListTrackingTarget.normalizedIDs(raw.compactMapValues { value in
            if let value = value as? String { return value }; return (value as? NSNumber)?.stringValue
        })
    }
    static func date(_ value: Any?) -> Date? {
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func target(movie: [String: Any]?, episode: [String: Any]?, show: [String: Any]?) -> MDBListTrackingTarget? {
        if let movie {
            let target = MDBListTrackingTarget(kind: .movie, ids: ids(movie))
            return target.valid ? target : nil
        }
        guard let episode, let show = show ?? episode["show"] as? [String: Any],
              let season = episode["season"] as? Int,
              let number = (episode["number"] ?? episode["episode"]) as? Int else { return nil }
        let tvdb = episode["tvdb_ids"] as? [String: Any]
        let display = episode["tvdb"] as? [String: Any]
        let target = MDBListTrackingTarget(kind: .episode, ids: ids(show), season: season, episode: number,
            episodeIDs: ids(episode), tvdbSeason: (tvdb?["season"] ?? display?["season"]) as? Int,
            tvdbEpisode: (tvdb?["episode"] ?? display?["number"] ?? display?["episode"]) as? Int,
            tvdbSeries: (tvdb?["series"] as? NSNumber)?.stringValue ?? ids(show)["tvdb"])
        return target.valid ? target : nil
    }
    static func history(_ object: [String: Any]) -> [MDBListTrackingRecord] {
        let movies = (object["movies"] as? [[String: Any]] ?? []).compactMap { row -> MDBListTrackingRecord? in
            guard let target = target(movie: row["movie"] as? [String: Any], episode: nil, show: nil),
                  let date = date(row["last_watched_at"] ?? row["watched_at"]) else { return nil }
            return .init(target: target, state: .watched, progress: 100, updatedAt: date)
        }
        return movies + (object["episodes"] as? [[String: Any]] ?? []).compactMap { row in
            guard let target = target(movie: nil, episode: row["episode"] as? [String: Any], show: row["show"] as? [String: Any]),
                  let date = date(row["last_watched_at"] ?? row["watched_at"]) else { return nil }
            return .init(target: target, state: .watched, progress: 100, updatedAt: date)
        }
    }
    static func playback(_ rows: [[String: Any]]) -> [MDBListTrackingRecord] {
        rows.compactMap { row in
            guard let target = target(movie: row["movie"] as? [String: Any], episode: row["episode"] as? [String: Any],
                                      show: row["show"] as? [String: Any]),
                  let progress = row["progress"] as? Double, progress.isFinite, (0...100).contains(progress),
                  let updated = date(row["updated_at"] ?? row["updated_at_ts"] ?? row["paused_at"]) else { return nil }
            if let expiry = date(row["expires_at"]), expiry <= Date() { return nil }
            return .init(target: target, state: .progress, progress: progress, updatedAt: updated,
                         runtime: (row["runtime"] as? Double ?? 0) * 60)
        }
    }
    static func upNext(_ rows: [[String: Any]]) -> [MDBListTrackingRecord] {
        rows.compactMap { row in
            guard let target = target(movie: nil, episode: row["next_episode"] as? [String: Any], show: row["show"] as? [String: Any]) else { return nil }
            return .init(target: target, state: .upNext, progress: 0,
                         updatedAt: date(row["last_watched_at"]) ?? .distantPast)
        }
    }
}
