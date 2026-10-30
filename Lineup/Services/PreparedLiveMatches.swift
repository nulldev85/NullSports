import Foundation

/// A day of matching is prepared while the app is open, never on the path from
/// a saved game to its player. Refresh is due after 24 hours; yesterday's
/// preparation may still cover today's games if a refresh fails.
/// Only the channels that actually matched this event, plus the guide evidence
/// used to match them. Reading this does not require the provider's full XMLTV
/// file or rebuilding its channel index. Empty results are retained too, so a
/// score update does not start the same unsuccessful search again.
struct PreparedLiveMatch: Codable, Sendable {
    let preparedAt: Date
    let eventStart: Date
    let identity: [String]
    let primary: XtreamStream?
    let alternatives: [LiveEventChannel]
    let programs: [String: [CurrentProgram]]
    let categoryNames: [String: String]

    static func identity(for game: SportsGame) -> [String] {
        ["prepared-v1", game.league.rawValue, game.awayTeam, game.homeTeam,
         game.awayAbbreviation, game.homeAbbreviation, game.broadcast,
         game.eventName ?? "", game.competition?.id ?? "", game.race?.kind ?? "",
         String(game.start.timeIntervalSince1970), game.venue ?? "", game.location ?? "",
         game.race?.eventID ?? "", game.race?.title ?? "", game.race?.circuit ?? "",
         game.league == .ncaaf && CollegeChannelMatcher.isDelayed(status: game.status) ? "delayed" : ""]
    }

    /// The identity used by the existing on-disk match cache before prepared
    /// snapshots. Read it only during migration; write the current identity.
    static func legacyIdentity(for game: SportsGame) -> [String] {
        ["quality-v1", game.league.rawValue, game.awayTeam, game.homeTeam,
         game.awayAbbreviation, game.homeAbbreviation, game.broadcast,
         game.eventName ?? "", game.competition?.id ?? "", game.race?.kind ?? "",
         String(game.start.timeIntervalSince1970)]
    }

    /// Ordered results of background matching, with no catalog discovery.
    /// An expired primary must not hide another prepared feed of this event.
    func playbackCandidates(for game: SportsGame, now: Date) -> [XtreamStream] {
        guard isCurrent(identity: Self.identity(for: game), now: now) else { return [] }
        var seen: Set<Int> = []
        let candidates = (primary.map { [$0] } ?? []) + alternatives.filter { !$0.sharedCoverage }.map(\.stream)
        let originalPoint = max(eventStart, preparedAt)
        let point = game.isLive ? now : game.start
        return candidates.filter { stream in
            guard seen.insert(stream.id).inserted else { return false }
            let entries = programs[stream.epgChannelID ?? ""] ?? []
            if let proof = entries.first(where: { $0.start <= originalPoint && originalPoint < $0.end }) {
                return point < proof.end
            }
            return true
        }
    }

    func covers(_ game: SportsGame, now: Date) -> Bool {
        guard isCurrent(identity: Self.identity(for: game), now: now) else { return false }
        if primary == nil && alternatives.allSatisfy(\.sharedCoverage) { return true }
        return !playbackCandidates(for: game, now: now).isEmpty
    }

    var streams: [XtreamStream] {
        var seen: Set<Int> = []
        return ((primary.map { [$0] } ?? []) + alternatives.map(\.stream))
            .filter { seen.insert($0.id).inserted }
    }

    func isCurrent(identity: [String], now: Date) -> Bool {
        self.identity == identity && PreparedMatchPolicy.canUse(preparedAt: preparedAt, now: now)
    }

    /// A new listing on an unrelated channel does not invalidate this event.
    /// A renamed/recycled stream, changed category, or changed guide binding
    /// does. Check against the full catalog only after it has been installed.
    func agreesWith(streams available: [Int: XtreamStream],
                    programs currentPrograms: [String: [CurrentProgram]],
                    categories: [String: String], checkGuide: Bool) -> Bool {
        streams.allSatisfy { streamIsCurrent($0, available: available,
            programs: currentPrograms, categories: categories, checkGuide: checkGuide) }
    }

    func streamIsCurrent(_ saved: XtreamStream, available: [Int: XtreamStream],
                         programs currentPrograms: [String: [CurrentProgram]],
                         categories: [String: String], checkGuide: Bool) -> Bool {
        guard let current = available[saved.id],
              DailyCachePolicy.isSameChannelSlot(cachedID: saved.id, freshID: current.id,
                cachedName: saved.name, freshName: current.name,
                cachedEPG: saved.epgChannelID, freshEPG: current.epgChannelID),
              current.streamType == saved.streamType, current.categoryID == saved.categoryID,
              (categories[current.categoryID ?? ""] ?? "") == (categoryNames[saved.categoryID ?? ""] ?? "") else { return false }
        let key = current.epgChannelID ?? ""
        let now = Date()
        let originalPoint = max(eventStart, preparedAt)
        let currentPoint = max(eventStart, now)
        func evidence(_ entries: [CurrentProgram]) -> [CurrentProgram] {
            entries.filter {
                ($0.start <= originalPoint && originalPoint < $0.end)
                    || ($0.start <= currentPoint && currentPoint < $0.end)
            }
        }
        return !checkGuide || evidence(currentPrograms[key] ?? []) == evidence(programs[key] ?? [])
    }

    func retaining(_ ids: Set<Int>) -> PreparedLiveMatch {
        let alternatives = alternatives.filter { ids.contains($0.id) }
        let primary = primary.flatMap { ids.contains($0.id) ? $0 : nil } ?? alternatives.first?.stream
        let kept = (primary.map { [$0] } ?? []) + alternatives.map(\.stream)
        let guideIDs = Set(kept.compactMap(\.epgChannelID))
        let categoryIDs = Set(kept.compactMap(\.categoryID))
        return .init(preparedAt: preparedAt, eventStart: eventStart, identity: identity, primary: primary,
                     alternatives: alternatives, programs: programs.filter { guideIDs.contains($0.key) },
                     categoryNames: categoryNames.filter { categoryIDs.contains($0.key) })
    }
}

/// A compact, independently readable launch file. Includes the schedule so
/// neither a network request nor a large channel/guide cache precedes playback.
/// Profile identity includes connection settings, never a password.
struct PreparedLiveSnapshot: Codable, Sendable {
    static let version = 1
    let version: Int
    let connection: [String]
    let savedAt: Date
    let dailyPreparedAt: Date?
    let games: [String: [SportsGame]]
    let loadedLeagues: Set<String>
    let matches: [String: PreparedLiveMatch]
    var playlistSources: Data? = nil

    static func connection(for profile: XtreamProfile) -> [String] {
        [profile.id.uuidString, profile.serverURL, profile.username, profile.connectionKind ?? ""]
    }

    func belongsTo(_ profile: XtreamProfile) -> Bool {
        version == Self.version && connection == Self.connection(for: profile)
    }
}

/// Application Support survives ordinary cache eviction. Each atomic write is
/// serialized by the owning library; no intermediate empty snapshot is written
/// while a refresh is waiting for the provider.
enum PreparedLiveStore {
    private static let writeLock = NSLock()
    static func directory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PreparedLive", isDirectory: true)
    }

    static func url(profileID: UUID, directory: URL? = nil) -> URL {
        (directory ?? Self.directory()).appendingPathComponent(profileID.uuidString + ".json")
    }

    static func read(profile: XtreamProfile, directory: URL? = nil) -> PreparedLiveSnapshot? {
        guard let data = try? Data(contentsOf: url(profileID: profile.id, directory: directory)),
              let saved = try? JSONDecoder().decode(PreparedLiveSnapshot.self, from: data),
              saved.belongsTo(profile) else { return nil }
        return saved
    }

    static func write(_ snapshot: PreparedLiveSnapshot, profileID: UUID, directory: URL? = nil) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let url = url(profileID: profileID, directory: directory)
        if let data = try? Data(contentsOf: url),
           let previous = try? JSONDecoder().decode(PreparedLiveSnapshot.self, from: data),
           previous.savedAt > snapshot.savedAt { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            var resource = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? resource.setResourceValues(values)
        } catch { /* Keep the last successfully written snapshot. */ }
    }

    static func remove(profileID: UUID, directory: URL? = nil) {
        writeLock.lock()
        defer { writeLock.unlock() }
        try? FileManager.default.removeItem(at: url(profileID: profileID, directory: directory))
    }
}
