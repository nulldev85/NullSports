import Foundation

private struct LibraryCache: Codable, Sendable {
    let categories: [XtreamCategory]
    let streams: [XtreamStream]
    let programsByChannel: [String: [CurrentProgram]]
    let guideUpdatedAt: Date?
    let libraryUpdatedAt: Date?
}

@MainActor
final class SportsLibrary: ObservableObject {
    @Published private(set) var profiles: [XtreamProfile] = []
    @Published var activeProfile: XtreamProfile?
    @Published private(set) var categories: [XtreamCategory] = []
    @Published private(set) var streams: [XtreamStream] = []
    @Published private(set) var professionalStreams: [XtreamStream] = []
    @Published private(set) var programsByChannel: [String: [CurrentProgram]] = [:]
    @Published private(set) var favoriteStreamOrder: [Int] = []
    @Published private(set) var gamesByLeague: [SportsLeague: [SportsGame]] = [:]
    @Published private(set) var scheduleLoadedLeagues: Set<SportsLeague> = []
    @Published private(set) var scheduleErrorMessage: String?
    @Published private(set) var isScheduleLoading = false
    @Published private(set) var isLoading = false
    @Published private(set) var isGuideLoading = false
    @Published var errorMessage: String?

    private let profilesKey = "NullSports.profiles"
    private let activeKey = "NullSports.activeProfile"
    private let favoritesKey = "NullSports.favoriteStreams"
    private var leagueStreamCache: [SportsLeague: [XtreamStream]] = [:]
    private var gameStreamCache: [String: XtreamStream] = [:]
    private var guideUpdatedAt: Date?
    private var libraryUpdatedAt: Date?
    private let guideLifetime: TimeInterval = 3 * 60 * 60
    private let libraryLifetime: TimeInterval = 6 * 60 * 60

    init() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([XtreamProfile].self, from: data) {
            profiles = decoded
        }
        if let id = UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:)) {
            activeProfile = profiles.first { $0.id == id }
        } else {
            activeProfile = profiles.first
        }
        favoriteStreamOrder = UserDefaults.standard.array(forKey: favoritesKey) as? [Int] ?? []
    }

    var hasProfile: Bool { activeProfile != nil }
    private func rebuildProfessionalStreams() {
        let categoryNames = categories.reduce(into: [String: String]()) { $0[$1.id] = $1.categoryName }
        professionalStreams = streams.filter { stream in
            let category = categoryNames[stream.categoryID ?? ""] ?? ""
            guard stream.streamType?.lowercased() != "radio_streams",
                  stream.streamType?.lowercased() != "radio" else { return false }
            guard !isExcluded(stream, categoryName: category) else { return false }
            let program = programs(for: stream).map { "\($0.title) \($0.detail)" }.joined(separator: " ")
            let searchable = "\(stream.name) \(category) \(program)"
            return SportsLeague.allCases.contains { $0.matches(searchable) }
        }
        leagueStreamCache = Dictionary(uniqueKeysWithValues: SportsLeague.allCases.map { league in
            (league, professionalStreams.filter { stream in
                let category = categoryNames[stream.categoryID ?? ""] ?? ""
                let listings = programs(for: stream).map { "\($0.title) \($0.detail)" }.joined(separator: " ")
                return league.matches("\(stream.name) \(category) \(listings)")
            })
        })
        rebuildGameStreamCache()
    }

    func addProfile(name: String, serverURL: String, username: String, password: String) async -> Bool {
        let profile = XtreamProfile(name: name.isEmpty ? "My IPTV" : name, serverURL: serverURL, username: username)
        do {
            let client = XtreamClient(profile: profile, password: password)
            let envelope = try await client.authenticate()
            guard envelope.userInfo?.auth == 1 else { throw XtreamClient.XtreamError.unauthorized }
            try KeychainStore.save(password: password, profileID: profile.id)
            profiles.append(profile)
            activeProfile = profile
            persistProfiles()
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func bootstrap() async {
        guard let profile = activeProfile else { return }
        if streams.isEmpty, let cached = await Self.readCache(profileID: profile.id) {
            categories = cached.categories
            streams = cached.streams
            programsByChannel = cached.programsByChannel
            guideUpdatedAt = cached.guideUpdatedAt
            libraryUpdatedAt = cached.libraryUpdatedAt
            rebuildProfessionalStreams()
        }
        refreshSchedule()
        if isLibraryFresh && isGuideFresh { return }
        await refreshLibrary(forceGuide: !isGuideFresh)
    }

    func reload() async {
        refreshSchedule()
        await refreshLibrary(forceGuide: true)
    }

    private func refreshLibrary(forceGuide: Bool) async {
        guard let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return }
        isLoading = streams.isEmpty
        errorMessage = nil
        do {
            let client = XtreamClient(profile: profile, password: password)
            async let loadedCategories = client.categories()
            async let loadedStreams = client.streams()
            categories = try await loadedCategories
            streams = try await loadedStreams
            libraryUpdatedAt = Date()
            rebuildProfessionalStreams()
            isLoading = false
            saveCache(profileID: profile.id)
            if forceGuide { refreshGuide(client: client, profileID: profile.id) }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshGuide(client: XtreamClient, profileID: UUID) {
        isGuideLoading = true
        Task { [weak self] in
            let programs = (try? await client.programsToday()) ?? [:]
            guard let self, self.activeProfile?.id == profileID else { return }
            self.programsByChannel = programs
            self.guideUpdatedAt = Date()
            self.rebuildProfessionalStreams()
            self.isGuideLoading = false
            self.saveCache(profileID: profileID)
        }
    }

    private var isGuideFresh: Bool {
        guard !programsByChannel.isEmpty, let guideUpdatedAt else { return false }
        return Calendar.current.isDate(guideUpdatedAt, inSameDayAs: Date())
            && Date().timeIntervalSince(guideUpdatedAt) < guideLifetime
    }

    private var isLibraryFresh: Bool {
        guard !streams.isEmpty, let libraryUpdatedAt else { return false }
        return Date().timeIntervalSince(libraryUpdatedAt) < libraryLifetime
    }

    private func saveCache(profileID: UUID) {
        let snapshot = LibraryCache(
            categories: categories,
            streams: streams,
            programsByChannel: programsByChannel,
            guideUpdatedAt: guideUpdatedAt,
            libraryUpdatedAt: libraryUpdatedAt
        )
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.cacheURL(profileID: profileID), options: .atomic)
        }
    }

    nonisolated private static func readCache(profileID: UUID) async -> LibraryCache? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: cacheURL(profileID: profileID)) else { return nil }
            return try? JSONDecoder().decode(LibraryCache.self, from: data)
        }.value
    }

    nonisolated private static func cacheURL(profileID: UUID) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("nullsports-\(profileID.uuidString).json")
    }

    func streams(for league: SportsLeague) -> [XtreamStream] {
        leagueStreamCache[league] ?? []
    }

    func games(for league: SportsLeague?) -> [SportsGame] {
        let games = league.map { gamesByLeague[$0] ?? [] } ?? SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }
        return games.filter { $0.isLive || $0.isUpcoming }.sorted { $0.start < $1.start }
    }

    func refreshSchedule() {
        guard !isScheduleLoading else { return }
        isScheduleLoading = true
        Task { [weak self] in
            let snapshot = await SportsScheduleClient().gamesToday()
            guard let self else { return }
            self.gamesByLeague = snapshot.games
            self.scheduleLoadedLeagues = snapshot.loadedLeagues
            self.scheduleErrorMessage = snapshot.errorMessage
            self.rebuildGameStreamCache()
            self.isScheduleLoading = false
        }
    }

    func scheduleAvailable(for league: SportsLeague?) -> Bool {
        if let league { return scheduleLoadedLeagues.contains(league) }
        return Set(SportsLeague.allCases).isSubset(of: scheduleLoadedLeagues)
    }

    func stream(for game: SportsGame) -> XtreamStream? {
        gameStreamCache[game.id]
    }

    private func matchedStream(for game: SportsGame) -> XtreamStream? {
        let candidates = streams(for: game.league)
        let away = game.awayTeam.lowercased()
        let home = game.homeTeam.lowercased()
        let awayNickname = away.split(separator: " ").last.map(String.init) ?? away
        let homeNickname = home.split(separator: " ").last.map(String.init) ?? home
        let broadcast = game.broadcast.lowercased()
        func rank(_ stream: XtreamStream) -> (namedTeamMatches: Int, score: Int) {
            let name = stream.name.lowercased()
            let guide = programs(for: stream).map { "\($0.title) \($0.detail)" }.joined(separator: " ").lowercased()
            let awayInName = name.contains(away) || name.contains(awayNickname)
            let homeInName = name.contains(home) || name.contains(homeNickname)
            let namedMatches = (awayInName ? 1 : 0) + (homeInName ? 1 : 0)
            let score = (name.contains(away) ? 16 : 0) + (name.contains(home) ? 16 : 0)
                + (name.contains(awayNickname) ? 10 : 0) + (name.contains(homeNickname) ? 10 : 0)
                + (guide.contains(away) ? 5 : 0) + (guide.contains(home) ? 5 : 0)
                + (guide.contains(awayNickname) ? 3 : 0) + (guide.contains(homeNickname) ? 3 : 0)
                + (!broadcast.isEmpty && name.contains(broadcast) ? 5 : 0)
                + (!broadcast.isEmpty && guide.contains(broadcast) ? 2 : 0)
                + (name.contains(game.league.rawValue) ? 1 : 0)
            return (namedMatches, score)
        }
        let ranked = candidates.map { ($0, rank($0)) }.sorted {
            if $0.1.namedTeamMatches != $1.1.namedTeamMatches {
                return $0.1.namedTeamMatches > $1.1.namedTeamMatches
            }
            return $0.1.score > $1.1.score
        }
        // A league-only or generic network match is not enough to identify a game.
        // Require at least one strong team match instead of opening an unrelated feed.
        guard let best = ranked.first, best.1.score >= 5 else { return nil }
        return best.0
    }

    private func rebuildGameStreamCache() {
        let games = SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }
        gameStreamCache = games.reduce(into: [:]) { result, game in
            if let stream = matchedStream(for: game) { result[game.id] = stream }
        }
    }

    func guidePrograms(for stream: XtreamStream) -> [CurrentProgram] {
        programs(for: stream)
    }

    func guideStreams(categoryID: String?, favoritesOnly: Bool, query: String) -> [XtreamStream] {
        let filtered = streams.filter { stream in
            guard stream.streamType?.lowercased() != "radio_streams",
                  stream.streamType?.lowercased() != "radio" else { return false }
            if favoritesOnly && !isFavorite(stream) { return false }
            if let categoryID, stream.categoryID != categoryID { return false }
            return query.isEmpty || stream.name.localizedCaseInsensitiveContains(query)
        }
        if favoritesOnly {
            let streamsByID = Dictionary(grouping: filtered, by: \.id).compactMapValues { $0.first }
            return favoriteStreamOrder.compactMap { streamsByID[$0] }
        }
        return filtered.sorted {
            if ($0.num ?? Int.max) != ($1.num ?? Int.max) { return ($0.num ?? Int.max) < ($1.num ?? Int.max) }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func isFavorite(_ stream: XtreamStream) -> Bool {
        favoriteStreamOrder.contains(stream.id)
    }

    func addFavorite(_ stream: XtreamStream) {
        guard !isFavorite(stream) else { return }
        favoriteStreamOrder.append(stream.id)
        persistFavorites()
    }

    func removeFavorite(_ stream: XtreamStream) {
        favoriteStreamOrder.removeAll { $0 == stream.id }
        persistFavorites()
    }

    func canMoveFavorite(_ stream: XtreamStream, offset: Int) -> Bool {
        guard let index = favoriteStreamOrder.firstIndex(of: stream.id) else { return false }
        return favoriteStreamOrder.indices.contains(index + offset)
    }

    func moveFavorite(_ stream: XtreamStream, offset: Int) {
        guard let index = favoriteStreamOrder.firstIndex(of: stream.id),
              favoriteStreamOrder.indices.contains(index + offset) else { return }
        favoriteStreamOrder.swapAt(index, index + offset)
        persistFavorites()
    }

    private func persistFavorites() {
        UserDefaults.standard.set(favoriteStreamOrder, forKey: favoritesKey)
    }

    private func programs(for stream: XtreamStream) -> [CurrentProgram] {
        guard let channelID = stream.epgChannelID else { return [] }
        return programsByChannel[channelID] ?? []
    }

    func playbackURLs(for stream: XtreamStream) -> [URL] {
        guard let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return [] }
        return XtreamClient(profile: profile, password: password).playbackURLs(for: stream)
    }

    private func isExcluded(_ stream: XtreamStream, categoryName: String) -> Bool {
        let value = "\(stream.name) \(categoryName)".lowercased()
        let blocked = ["radio", "audio", "sirius", "xm ", "music", "podcast", "fm ", "am ", "nfhs", "high school", "ncaa", "ncaaf", "ncaab", "college", "university", "wnba", "acc network", "sec network", "big ten network", "big 12", "pac-12"]
        return blocked.contains { value.contains($0) }
    }

    func removeActiveProfile() {
        guard let profile = activeProfile else { return }
        KeychainStore.delete(profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        activeProfile = profiles.first
        categories = []
        streams = []
        professionalStreams = []
        leagueStreamCache = [:]
        gameStreamCache = [:]
        programsByChannel = [:]
        gamesByLeague = [:]
        scheduleLoadedLeagues = []
        scheduleErrorMessage = nil
        isScheduleLoading = false
        isGuideLoading = false
        guideUpdatedAt = nil
        libraryUpdatedAt = nil
        try? FileManager.default.removeItem(at: Self.cacheURL(profileID: profile.id))
        persistProfiles()
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(activeProfile?.id.uuidString, forKey: activeKey)
    }
}
