import Foundation

private struct LibraryCache: Codable, Sendable {
    let categories: [XtreamCategory]
    let streams: [XtreamStream]
    let programsByChannel: [String: [CurrentProgram]]
    let guideUpdatedAt: Date?
    let libraryUpdatedAt: Date?
}

private struct SportsIndex: Sendable {
    let professional: [XtreamStream]
    let leagues: [SportsLeague: [XtreamStream]]
    let searchText: [Int: String]
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
    @Published private(set) var isRefreshingData = false
    @Published var errorMessage: String?

    private let profilesKey = "NullSports.profiles"
    private let activeKey = "NullSports.activeProfile"
    private let favoritesKey = "NullSports.favoriteStreams"
    private let scheduleKey = "NullSports.lastGoodSchedule"
    private var leagueStreamCache: [SportsLeague: [XtreamStream]] = [:]
    private var streamSearchText: [Int: String] = [:]
    @Published private var gameStreamCache: [String: XtreamStream] = [:]
    private var gameMatchSignatures: [String: String] = [:]
    private var indexGeneration = UUID()
    private var matchGeneration = UUID()
    private var guideListCache: (category: String?, favorites: Bool, query: String, streams: [XtreamStream])?
    private var didRestoreSchedule = false
    private var bootstrapInFlight = false
    private var libraryRefreshInFlight = false
    private var cacheWriteTask: Task<Void, Never>?
    private var scheduleWriteTask: Task<Void, Never>?
    private var scheduleRefreshInFlight = false
    private var activeRefreshOperations = 0
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
    private func rebuildProfessionalStreams() async {
        let generation = UUID()
        indexGeneration = generation
        let profileID = activeProfile?.id
        let currentCategories = categories
        let currentStreams = streams
        let currentPrograms = programsByChannel
        let index = await Task.detached(priority: .utility) {
            Self.makeSportsIndex(categories: currentCategories, streams: currentStreams, programs: currentPrograms)
        }.value
        guard indexGeneration == generation, activeProfile?.id == profileID else { return }
        professionalStreams = index.professional
        leagueStreamCache = index.leagues
        streamSearchText = index.searchText
        await rebuildGameStreamCache(force: true)
    }

    nonisolated private static func makeSportsIndex(
        categories: [XtreamCategory], streams: [XtreamStream], programs: [String: [CurrentProgram]]
    ) -> SportsIndex {
        let categoryNames = categories.reduce(into: [String: String]()) { $0[$1.id] = $1.categoryName }
        let programText = programs.mapValues { listings in
            listings.map { "\($0.title) \($0.detail)" }.joined(separator: " ").lowercased()
        }
        let blocked = ["radio", "audio", "sirius", "xm ", "music", "podcast", "fm ", "am ", "nfhs", "high school", "ncaab", "college basketball", "wnba"]
        let college = ["ncaa", "ncaaf", "college", "university", "acc network", "sec network", "big ten network", "big 12", "pac-12"]
        var searchText: [Int: String] = [:]
        var collegeStreamIDs: Set<Int> = []
        let professional = streams.filter { stream in
            let category = categoryNames[stream.categoryID ?? ""] ?? ""
            let type = stream.streamType?.lowercased()
            guard type != "radio_streams", type != "radio" else { return false }
            let base = "\(stream.name) \(category)".lowercased()
            guard !blocked.contains(where: { base.contains($0) }) else { return false }
            if college.contains(where: { base.contains($0) }) { collegeStreamIDs.insert(stream.id) }
            let searchable = "\(base) \(stream.epgChannelID.flatMap { programText[$0] } ?? "")"
            searchText[stream.id] = searchable
            return SportsLeague.allCases.contains { $0.matches(searchable) }
        }
        let leagues = Dictionary(uniqueKeysWithValues: SportsLeague.allCases.map { league in
            (league, professional.filter {
                (league == .ncaaf || !collegeStreamIDs.contains($0.id))
                    && league.matches(searchText[$0.id] ?? $0.name)
            })
        })
        return SportsIndex(professional: professional, leagues: leagues, searchText: searchText)
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
        guard let profile = activeProfile, !bootstrapInFlight else { return }
        bootstrapInFlight = true
        beginRefreshOperation()
        defer { bootstrapInFlight = false; endRefreshOperation() }
        if !didRestoreSchedule {
            let key = scheduleKey
            let cached = await Task.detached(priority: .utility) { () -> [String: [SportsGame]]? in
                guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
                return try? JSONDecoder().decode([String: [SportsGame]].self, from: data)
            }.value
            guard activeProfile?.id == profile.id else { return }
            didRestoreSchedule = true
            if let cached, gamesByLeague.isEmpty {
                gamesByLeague = Dictionary(uniqueKeysWithValues: SportsLeague.allCases.map { ($0, cached[$0.rawValue] ?? []) })
                scheduleLoadedLeagues = Set(cached.keys.compactMap(SportsLeague.init(rawValue:)))
            }
        }
        refreshSchedule(showsLoading: false)
        if streams.isEmpty, let cached = await Self.readCache(profileID: profile.id) {
            guard activeProfile?.id == profile.id else { return }
            categories = cached.categories
            streams = cached.streams
            guideListCache = nil
            programsByChannel = cached.programsByChannel
            guideUpdatedAt = cached.guideUpdatedAt
            libraryUpdatedAt = cached.libraryUpdatedAt
            await rebuildProfessionalStreams()
        }
        guard activeProfile?.id == profile.id else { return }
        if isLibraryFresh && isGuideFresh { return }
        await refreshLibrary(forceGuide: !isGuideFresh, refreshChannels: !isLibraryFresh)
    }

    func reload() async {
        beginRefreshOperation()
        defer { endRefreshOperation() }
        refreshSchedule()
        await refreshLibrary(forceGuide: true)
    }

    private func refreshLibrary(forceGuide: Bool, refreshChannels: Bool = true) async {
        guard !libraryRefreshInFlight,
              let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return }
        libraryRefreshInFlight = true
        beginRefreshOperation()
        defer { libraryRefreshInFlight = false; endRefreshOperation() }
        isLoading = refreshChannels && streams.isEmpty
        errorMessage = nil
        let client = XtreamClient(profile: profile, password: password)
        if forceGuide { refreshGuide(client: client, profileID: profile.id) }
        guard refreshChannels else { return }
        do {
            async let loadedCategories = client.categories()
            async let loadedStreams = client.streams()
            let (newCategories, newStreams) = try await (loadedCategories, loadedStreams)
            guard activeProfile?.id == profile.id else { return }
            let changed = categories != newCategories || streams != newStreams
            if categories != newCategories { categories = newCategories }
            if streams != newStreams {
                guideListCache = nil
                streams = newStreams
            }
            libraryUpdatedAt = Date()
            if changed { await rebuildProfessionalStreams() }
            guard activeProfile?.id == profile.id else { return }
            isLoading = false
            saveCache(profileID: profile.id)
        } catch {
            guard activeProfile?.id == profile.id else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshGuide(client: XtreamClient, profileID: UUID) {
        guard !isGuideLoading else { return }
        isGuideLoading = true
        beginRefreshOperation()
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeProfile?.id == profileID { self.isGuideLoading = false }
                self.endRefreshOperation()
            }
            // Keep the last good guide and its timestamp when a refresh fails.
            guard let programs = try? await client.programsToday() else { return }
            guard self.activeProfile?.id == profileID else { return }
            self.guideUpdatedAt = Date()
            if self.programsByChannel != programs {
                self.programsByChannel = programs
                await self.rebuildProfessionalStreams()
            }
            guard self.activeProfile?.id == profileID else { return }
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
        let previousWrite = cacheWriteTask
        cacheWriteTask = Task.detached(priority: .utility) {
            await previousWrite?.value
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

    func scoreTickerGames() -> [SportsGame] {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let games = SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }
        return games
            .filter {
                $0.start >= today && $0.start < tomorrow
                    && ($0.isLive || $0.state == "post")
                    && !$0.awayScore.isEmpty && !$0.homeScore.isEmpty
            }
            .sorted {
                if $0.isLive != $1.isLive { return $0.isLive }
                return $0.isLive ? $0.start < $1.start : $0.start > $1.start
            }
    }

    func refreshSchedule(showsLoading: Bool = true) {
        guard !scheduleRefreshInFlight else { return }
        let profileID = activeProfile?.id
        scheduleRefreshInFlight = true
        let tracksNetworkRefresh = showsLoading
        if tracksNetworkRefresh { beginRefreshOperation() }
        if showsLoading { isScheduleLoading = true }
        Task { [weak self] in
            let snapshot = await SportsScheduleClient().gamesToday()
            guard let self else { return }
            var tracksProcessingRefresh = false
            defer {
                self.scheduleRefreshInFlight = false
                if showsLoading { self.isScheduleLoading = false }
                if tracksNetworkRefresh || tracksProcessingRefresh { self.endRefreshOperation() }
            }
            guard self.activeProfile?.id == profileID else { return }
            if !snapshot.loadedLeagues.isEmpty {
                var updatedGames = self.gamesByLeague
                for league in snapshot.loadedLeagues {
                    updatedGames[league] = snapshot.games[league] ?? []
                }
                if updatedGames != self.gamesByLeague {
                    if !tracksNetworkRefresh {
                        self.beginRefreshOperation()
                        tracksProcessingRefresh = true
                    }
                    self.gamesByLeague = updatedGames
                    self.persistSchedule(loadedLeagues: self.scheduleLoadedLeagues.union(snapshot.loadedLeagues))
                    await self.rebuildGameStreamCache()
                }
                guard self.activeProfile?.id == profileID else { return }
                let loadedLeagues = self.scheduleLoadedLeagues.union(snapshot.loadedLeagues)
                if loadedLeagues != self.scheduleLoadedLeagues { self.scheduleLoadedLeagues = loadedLeagues }
            }
            if self.scheduleErrorMessage != snapshot.errorMessage { self.scheduleErrorMessage = snapshot.errorMessage }
        }
    }

    private func beginRefreshOperation() {
        activeRefreshOperations += 1
        if !isRefreshingData { isRefreshingData = true }
    }

    private func endRefreshOperation() {
        activeRefreshOperations = max(0, activeRefreshOperations - 1)
        if activeRefreshOperations == 0 { isRefreshingData = false }
    }

    private func persistSchedule(loadedLeagues: Set<SportsLeague>) {
        let value = Dictionary(uniqueKeysWithValues: loadedLeagues.map { ($0.rawValue, gamesByLeague[$0] ?? []) })
        let key = scheduleKey
        let previousWrite = scheduleWriteTask
        scheduleWriteTask = Task.detached(priority: .utility) {
            await previousWrite?.value
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    func scheduleAvailable(for league: SportsLeague?) -> Bool {
        if let league { return scheduleLoadedLeagues.contains(league) }
        return Set(SportsLeague.allCases).isSubset(of: scheduleLoadedLeagues)
    }

    func stream(for game: SportsGame) -> XtreamStream? {
        gameStreamCache[game.id]
    }

    nonisolated private static func matchedStream(for game: SportsGame, candidates: [XtreamStream], searchText: [Int: String]) -> XtreamStream? {
        let away = game.awayTeam.lowercased()
        let home = game.homeTeam.lowercased()
        let awayNickname = away.split(separator: " ").last.map(String.init) ?? away
        let homeNickname = home.split(separator: " ").last.map(String.init) ?? home
        let broadcast = game.broadcast.lowercased()
        func rank(_ stream: XtreamStream) -> (namedTeamMatches: Int, score: Int) {
            let name = stream.name.lowercased()
            let guide = searchText[stream.id] ?? name
            if game.league == .ncaaf {
                // College mascots are shared by many schools. A nickname alone
                // must not select an unrelated school's feed.
                let tokens = Set(guide.components(separatedBy: CharacterSet.alphanumerics.inverted))
                let awayAbbreviation = game.awayAbbreviation.lowercased()
                let homeAbbreviation = game.homeAbbreviation.lowercased()
                let awayMatches = guide.contains(away) || (awayAbbreviation.count >= 3 && tokens.contains(awayAbbreviation))
                let homeMatches = guide.contains(home) || (homeAbbreviation.count >= 3 && tokens.contains(homeAbbreviation))
                guard awayMatches || homeMatches else { return (0, 0) }
                let namedMatches = (name.contains(away) ? 1 : 0) + (name.contains(home) ? 1 : 0)
                return (namedMatches, namedMatches * 16 + (awayMatches ? 5 : 0) + (homeMatches ? 5 : 0)
                    + (!broadcast.isEmpty && name.contains(broadcast) ? 2 : 0))
            }
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
        var best: (stream: XtreamStream, namedTeamMatches: Int, score: Int)?
        for candidate in candidates {
            let score = rank(candidate)
            if let current = best {
                guard score.namedTeamMatches > current.namedTeamMatches
                    || (score.namedTeamMatches == current.namedTeamMatches && score.score > current.score) else { continue }
            }
            best = (candidate, score.namedTeamMatches, score.score)
        }
        // A league-only or generic network match is not enough to identify a game.
        // Require at least one strong team match instead of opening an unrelated feed.
        guard let best, best.score >= 5 else { return nil }
        return best.stream
    }

    private func rebuildGameStreamCache(force: Bool = false) async {
        let generation = UUID()
        matchGeneration = generation
        let profileID = activeProfile?.id
        let games = SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }
        let leagues = leagueStreamCache
        let searchText = streamSearchText
        let previousMatches = gameStreamCache
        // Invalidate signatures immediately so an overlapping schedule update also
        // rematches against a newly installed channel index.
        if force { gameMatchSignatures = [:] }
        let previousSignatures = gameMatchSignatures
        let result = await Task.detached(priority: .utility) {
            let activeIDs = Set(games.map(\.id))
            var matches = previousMatches.filter { activeIDs.contains($0.key) }
            var signatures = previousSignatures.filter { activeIDs.contains($0.key) }
            for game in games {
                let signature = "\(game.league.rawValue)|\(game.awayTeam)|\(game.homeTeam)|\(game.broadcast)"
                guard signatures[game.id] != signature else { continue }
                if let stream = Self.matchedStream(for: game, candidates: leagues[game.league] ?? [], searchText: searchText) { matches[game.id] = stream }
                else { matches.removeValue(forKey: game.id) }
                signatures[game.id] = signature
            }
            return (matches, signatures)
        }.value
        guard matchGeneration == generation, activeProfile?.id == profileID else { return }
        if gameStreamCache != result.0 { gameStreamCache = result.0 }
        gameMatchSignatures = result.1
    }

    func guidePrograms(for stream: XtreamStream) -> [CurrentProgram] {
        programs(for: stream)
    }

    func guideStreams(categoryID: String?, favoritesOnly: Bool, query: String) -> [XtreamStream] {
        if let cached = guideListCache, cached.category == categoryID,
           cached.favorites == favoritesOnly, cached.query == query { return cached.streams }
        let filtered = streams.filter { stream in
            guard stream.streamType?.lowercased() != "radio_streams",
                  stream.streamType?.lowercased() != "radio" else { return false }
            if favoritesOnly && !isFavorite(stream) { return false }
            if let categoryID, stream.categoryID != categoryID { return false }
            return query.isEmpty || stream.name.localizedCaseInsensitiveContains(query)
        }
        let result: [XtreamStream]
        if favoritesOnly {
            let streamsByID = Dictionary(grouping: filtered, by: \.id).compactMapValues { $0.first }
            result = favoriteStreamOrder.compactMap { streamsByID[$0] }
        } else {
            result = filtered.sorted {
                if ($0.num ?? Int.max) != ($1.num ?? Int.max) { return ($0.num ?? Int.max) < ($1.num ?? Int.max) }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        guideListCache = (categoryID, favoritesOnly, query, result)
        return result
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
        guideListCache = nil
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
        indexGeneration = UUID()
        matchGeneration = UUID()
        guideListCache = nil
        categories = []
        streams = []
        professionalStreams = []
        leagueStreamCache = [:]
        streamSearchText = [:]
        gameStreamCache = [:]
        gameMatchSignatures = [:]
        programsByChannel = [:]
        gamesByLeague = [:]
        scheduleLoadedLeagues = []
        scheduleErrorMessage = nil
        isScheduleLoading = false
        isGuideLoading = false
        isLoading = false
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
