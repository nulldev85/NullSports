import Foundation
import OSLog

private struct LibraryCache: Codable, Sendable {
    let categories: [XtreamCategory]
    let streams: [XtreamStream]
    let programsByChannel: [String: [CurrentProgram]]
    let guideUpdatedAt: Date?
    let libraryUpdatedAt: Date?
    // Optional fields keep older installations' library caches readable.
    let matchCacheVersion: Int?
    let dailyMatches: DailyGameMatches<XtreamStream>?
    let sportsIndex: SportsIndex?
}

private struct SportsIndex: Codable, Sendable {
    let professional: [XtreamStream]
    let leagues: [SportsLeague: [XtreamStream]]
    let searchText: [Int: String]
}

private struct ScheduleCache: Codable, Sendable {
    let savedAt: Date
    let games: [String: [SportsGame]]
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
    private let scheduleKey = "NullSports.lastGoodSchedule"
    private var leagueStreamCache: [SportsLeague: [XtreamStream]] = [:]
    private var streamSearchText: [Int: String] = [:]
    private var sportsIndexReady = false
    @Published private var gameStreamCache: [String: XtreamStream] = [:]
    private var gameMatchSignatures: [String: String] = [:]
    private var matchedGameIdentities: [String: [String]] = [:]
    private var indexGeneration = UUID()
    private var matchGeneration = UUID()
    private var guideListCache: (category: String?, favorites: Bool, query: String, streams: [XtreamStream])?
    private var didRestoreSchedule = false
    private var scheduleDay: Date?
    private var bootstrapInFlight = false
    private var libraryRefreshInFlight = false
    private var channelMatchingWorkCount = 0
    private var cacheWriteTask: Task<Void, Never>?
    private var scheduleWriteTask: Task<Void, Never>?
    private var scheduleRefreshInFlight = false
    private var lastSavedMatchIdentities: [String: [String]] = [:]
    private var lastSavedMatchDay: Date?
    private var guideUpdatedAt: Date?
    private var libraryUpdatedAt: Date?
    private var tomorrowScheduleUpdatedAt: Date?
    private let guideLifetime: TimeInterval = 3 * 60 * 60
    private let libraryLifetime: TimeInterval = 6 * 60 * 60
    private let tomorrowScheduleLifetime: TimeInterval = 3 * 60 * 60

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

    // Consulted only after a selection has no verified match. Score polling alone
    // does not prevent manual selection, and cached verified matches remain usable.
    var channelsAreSyncing: Bool {
        bootstrapInFlight || libraryRefreshInFlight || isGuideLoading || channelMatchingWorkCount > 0
    }

    private func rebuildProfessionalStreams() async {
        sportsIndexReady = false
        channelMatchingWorkCount += 1
        defer { channelMatchingWorkCount -= 1 }
        let generation = UUID()
        indexGeneration = generation
        let profileID = activeProfile?.id
        let currentCategories = categories
        let currentStreams = streams
        let currentPrograms = programsByChannel
        let index = await Task.detached(priority: .utility) {
            Self.makeSportsIndex(categories: currentCategories, streams: currentStreams, programs: currentPrograms)
        }.value
        guard DailyCachePolicy.shouldApplyRebuild(resultGeneration: generation, currentGeneration: indexGeneration,
            resultProfileID: profileID, currentProfileID: activeProfile?.id) else { return }
        professionalStreams = index.professional
        leagueStreamCache = index.leagues
        streamSearchText = index.searchText
        sportsIndexReady = true
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
        defer { bootstrapInFlight = false }
        if !didRestoreSchedule {
            let key = scheduleKey
            let cached = await Task.detached(priority: .utility) { () -> ScheduleCache? in
                guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
                // Undated legacy snapshots need a fresh fetch, not a guessed date.
                return try? JSONDecoder().decode(ScheduleCache.self, from: data)
            }.value
            guard activeProfile?.id == profile.id else { return }
            didRestoreSchedule = true
            if let cached, DailyCachePolicy.isCurrent(savedAt: cached.savedAt, now: Date()), gamesByLeague.isEmpty {
                gamesByLeague = Dictionary(uniqueKeysWithValues: SportsLeague.allCases.map { ($0, cached.games[$0.rawValue] ?? []) })
                scheduleLoadedLeagues = Set(cached.games.keys.compactMap(SportsLeague.init(rawValue:)))
                scheduleDay = Calendar.current.startOfDay(for: Date())
            }
        }
        if streams.isEmpty, let cached = await Self.readCache(profileID: profile.id) {
            guard activeProfile?.id == profile.id else { return }
            categories = cached.categories
            streams = cached.streams
            guideListCache = nil
            programsByChannel = cached.programsByChannel
            guideUpdatedAt = cached.guideUpdatedAt
            libraryUpdatedAt = cached.libraryUpdatedAt
            let now = Date()
            if cached.matchCacheVersion == 1, let saved = cached.dailyMatches {
                gameStreamCache = saved.restore(identities: matchIdentities(now: now), available: streams, now: now)
                matchedGameIdentities = saved.identities.filter { gameStreamCache[$0.key] != nil }
                lastSavedMatchIdentities = saved.identities
                lastSavedMatchDay = saved.savedAt
                // Preserve the existing professional matching policy's signatures.
                for game in gamesByLeague.values.flatMap({ $0 }) where game.league != .ncaaf && gameStreamCache[game.id] != nil {
                    gameMatchSignatures[game.id] = "\(game.league.rawValue)|\(game.awayTeam)|\(game.homeTeam)|\(game.broadcast)"
                }
            }
            if cached.matchCacheVersion == 1, let saved = cached.dailyMatches,
               DailyCachePolicy.isCurrent(savedAt: saved.savedAt, now: now),
               let index = cached.sportsIndex,
               DailyCachePolicy.hasCompleteIndex(savedLeagues: Set(index.leagues.keys.map(\.rawValue)),
                   expectedLeagues: Set(SportsLeague.allCases.map(\.rawValue))) {
                professionalStreams = index.professional
                leagueStreamCache = index.leagues
                streamSearchText = index.searchText
                sportsIndexReady = true
                if matchIdentities(now: now).keys.contains(where: { gameStreamCache[$0] == nil }) {
                    await rebuildGameStreamCache()
                }
            } else {
                await rebuildProfessionalStreams()
            }
        }
        guard activeProfile?.id == profile.id else { return }
        // Publish saved matches before any network refresh can start rematching.
        refreshSchedule(showsLoading: false)
        if isLibraryFresh && isGuideFresh { return }
        await refreshLibrary(forceGuide: !isGuideFresh, refreshChannels: !isLibraryFresh)
    }

    func reload() async {
        refreshSchedule()
        await refreshLibrary(forceGuide: true)
    }

    private func refreshLibrary(forceGuide: Bool, refreshChannels: Bool = true) async {
        guard !libraryRefreshInFlight,
              let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return }
        libraryRefreshInFlight = true
        defer { libraryRefreshInFlight = false }
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
            let oldCategories = categories
            let oldStreams = streams
            let changes = await Task.detached(priority: .utility) {
                (oldCategories != newCategories, oldStreams != newStreams)
            }.value
            guard activeProfile?.id == profile.id else { return }
            if changes.0 { categories = newCategories }
            if changes.1 {
                guideListCache = nil
                streams = newStreams
            }
            libraryUpdatedAt = Date()
            if changes.0 || changes.1 { await rebuildProfessionalStreams() }
            guard activeProfile?.id == profile.id else { return }
            isLoading = false
            saveCache(profileID: profile.id)
        } catch {
            guard activeProfile?.id == profile.id else { return }
            isLoading = false
            if streams.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func refreshGuide(client: XtreamClient, profileID: UUID) {
        guard !isGuideLoading else { return }
        isGuideLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeProfile?.id == profileID { self.isGuideLoading = false }
            }
            // Keep the last good guide and its timestamp when a refresh fails.
            guard let programs = try? await client.programsToday() else { return }
            guard self.activeProfile?.id == profileID else { return }
            let previousPrograms = self.programsByChannel
            let changed = await Task.detached(priority: .utility) { previousPrograms != programs }.value
            guard self.activeProfile?.id == profileID else { return }
            self.guideUpdatedAt = Date()
            if changed {
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
        let now = Date()
        let identities = matchIdentities(now: now)
        let snapshot = LibraryCache(
            categories: categories,
            streams: streams,
            programsByChannel: programsByChannel,
            guideUpdatedAt: guideUpdatedAt,
            libraryUpdatedAt: libraryUpdatedAt,
            matchCacheVersion: 1,
            dailyMatches: DailyGameMatches(savedAt: now, identities: matchedGameIdentities,
                channels: gameStreamCache.filter { key, _ in
                    identities[key] != nil && identities[key] == matchedGameIdentities[key]
                }),
            sportsIndex: sportsIndexReady ? SportsIndex(professional: professionalStreams, leagues: leagueStreamCache, searchText: streamSearchText) : nil
        )
        lastSavedMatchIdentities = identities
        lastSavedMatchDay = now
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
                // A final whistle or a score update must not reshuffle the ticker.
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }
    }

    // `includeTomorrow: false` is for frequent, light-weight callers (e.g. a live-score
    // poll) that only need today's slate refreshed. Tomorrow's already-known games are
    // preserved rather than dropped, and are still refetched on their own lifetime.
    func refreshSchedule(showsLoading: Bool = false, includeTomorrow: Bool = true) {
        let today = Calendar.current.startOfDay(for: Date())
        if scheduleDay != today {
            scheduleDay = today
            gamesByLeague = [:]
            scheduleLoadedLeagues = []
            gameStreamCache = [:]
            gameMatchSignatures = [:]
            matchedGameIdentities = [:]
            matchGeneration = UUID()
            scheduleErrorMessage = nil
            tomorrowScheduleUpdatedAt = nil
        }
        guard !scheduleRefreshInFlight else { return }
        let profileID = activeProfile?.id
        scheduleRefreshInFlight = true
        if showsLoading { isScheduleLoading = true }
        let fetchesTomorrow = includeTomorrow
            || tomorrowScheduleUpdatedAt == nil
            || Date().timeIntervalSince(tomorrowScheduleUpdatedAt!) >= tomorrowScheduleLifetime
        Task { [weak self] in
            let snapshot = await SportsScheduleClient().gamesToday(includeTomorrow: fetchesTomorrow)
            guard let self else { return }
            defer {
                self.scheduleRefreshInFlight = false
                if showsLoading { self.isScheduleLoading = false }
            }
            guard self.activeProfile?.id == profileID else { return }
            // A response started yesterday cannot repopulate today's slate.
            guard Calendar.current.isDate(today, inSameDayAs: Date()) else { return }
            if fetchesTomorrow { self.tomorrowScheduleUpdatedAt = Date() }
            if !snapshot.loadedLeagues.isEmpty {
                let previousGames = self.gamesByLeague
                let tomorrowStart = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
                let update = await Task.detached(priority: .utility) {
                    var games = previousGames
                    for league in snapshot.loadedLeagues {
                        let fresh = snapshot.games[league] ?? []
                        if fetchesTomorrow {
                            games[league] = fresh
                        } else {
                            // This fetch only covers today; keep the tomorrow games
                            // already on hand instead of discarding them.
                            let keptTomorrow = (previousGames[league] ?? []).filter { $0.start >= tomorrowStart }
                            games[league] = (fresh + keptTomorrow).sorted { $0.start < $1.start }
                        }
                    }
                    return (games, games != previousGames)
                }.value
                guard self.activeProfile?.id == profileID,
                      Calendar.current.isDate(today, inSameDayAs: Date()) else { return }
                if update.1 {
                    self.gamesByLeague = update.0
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

    private func persistSchedule(loadedLeagues: Set<SportsLeague>) {
        let value = ScheduleCache(savedAt: Date(), games: Dictionary(uniqueKeysWithValues: loadedLeagues.map { ($0.rawValue, gamesByLeague[$0] ?? []) }))
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

    private func matchIdentities(now: Date) -> [String: [String]] {
        let day = Calendar.current.startOfDay(for: now)
        return gamesByLeague.values.flatMap { $0 }.reduce(into: [:]) { result, game in
            guard game.isLive || game.isUpcoming,
                  game.start >= day || (game.isLive && now.timeIntervalSince(game.start) < 12 * 60 * 60) else { return }
            result[game.id] = Self.matchIdentity(game)
        }
    }

    nonisolated private static func matchIdentity(_ game: SportsGame) -> [String] {
        [game.league.rawValue, game.awayTeam, game.homeTeam,
         game.awayAbbreviation, game.homeAbbreviation, game.broadcast,
         String(game.start.timeIntervalSince1970)]
    }

    // Only playback actions revalidate. Row rendering must remain a cheap lookup.
    func verifiedStream(for game: SportsGame) -> XtreamStream? {
        guard let stream = gameStreamCache[game.id],
              matchedGameIdentities[game.id] == Self.matchIdentity(game) else { return nil }
        if game.league == .ncaaf {
            // Revalidate at selection time even if a score refresh had no changes.
            let matchup = Self.collegeMatchup(game)
            let slate = (gamesByLeague[.ncaaf] ?? []).filter { $0.isLive || $0.isUpcoming }.map(Self.collegeMatchup)
            guard CollegeChannelMatcher.score(channel: stream.name,
                listings: Self.collegeListings(programs(for: stream)),
                game: matchup, now: Date(),
                allowNetworkFallback: CollegeChannelMatcher.allowsNetworkFallback(for: matchup, slate: slate)) != nil else { return nil }
        }
        return stream
    }

    nonisolated private static func collegeMatchup(_ game: SportsGame) -> CollegeChannelMatcher.Matchup {
        .init(broadcast: game.broadcast, away: game.awayTeam, home: game.homeTeam,
              awayAbbreviation: game.awayAbbreviation, homeAbbreviation: game.homeAbbreviation,
              kickoff: game.start, isLive: game.isLive, status: game.status)
    }

    nonisolated private static func collegeListings(_ programs: [CurrentProgram]) -> [CollegeChannelMatcher.Listing] {
        programs.map { .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end) }
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
        // A schedule response may arrive before startup/index rebuilding finishes.
        // The completed index rebuild will match the latest schedule itself.
        guard sportsIndexReady else { return }
        channelMatchingWorkCount += 1
        defer { channelMatchingWorkCount -= 1 }
        let generation = UUID()
        matchGeneration = generation
        let profileID = activeProfile?.id
        let games = SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }
        let leagues = leagueStreamCache
        let searchText = streamSearchText
        let programs = programsByChannel
        // College event channels may have neither a league token nor a network
        // name. Let the college policy inspect them without changing other indexes.
        let currentStreams = streams
        let currentCategories = categories
        let now = Date()
        let identities = matchIdentities(now: now)
        let previousMatches = gameStreamCache
        // Invalidate signatures immediately so an overlapping schedule update also
        // rematches against a newly installed channel index.
        if force { gameMatchSignatures = [:] }
        let previousSignatures = gameMatchSignatures
        let result = await Task.detached(priority: .utility) {
            let collegeSlate = games.filter { $0.league == .ncaaf && ($0.isLive || $0.isUpcoming) }.map(Self.collegeMatchup)
            let categoryNames = currentCategories.reduce(into: [String: String]()) { $0[$1.id] = $1.categoryName.lowercased() }
            let collegeStreams = collegeSlate.isEmpty ? [] : currentStreams.filter { stream in
                let category = categoryNames[stream.categoryID ?? ""] ?? ""
                return !["radio", "radio_streams"].contains(stream.streamType?.lowercased() ?? "")
                    && !["radio", "audio", "basketball", "ncaab", "high school", "nfhs"].contains(where: { category.contains($0) })
            }
            // Normalize each guide channel once, including duplicate stream qualities.
            var collegePrograms: [String: [CollegeChannelMatcher.Listing]] = [:]
            let collegeCandidates = collegeStreams.map { stream in
                let key = stream.epgChannelID ?? ""
                if collegePrograms[key] == nil { collegePrograms[key] = Self.collegeListings(programs[key] ?? []) }
                return CollegeChannelMatcher.Candidate(id: stream.id, name: stream.name, listings: collegePrograms[key] ?? [])
            }
            let activeIDs = Set(games.map(\.id))
            var matches = previousMatches.filter { activeIDs.contains($0.key) }
            var signatures = previousSignatures.filter { activeIDs.contains($0.key) }
            for game in games {
                if game.league == .ncaaf {
                    guard game.isLive || game.isUpcoming else { matches[game.id] = nil; continue }
                    let matchup = Self.collegeMatchup(game)
                    let selectedID = CollegeChannelMatcher.select(collegeCandidates, game: matchup, now: now,
                        allowNetworkFallback: CollegeChannelMatcher.allowsNetworkFallback(for: matchup, slate: collegeSlate))
                    let selected = selectedID.flatMap { id in collegeStreams.first { $0.id == id } }
                    matches[game.id] = selected
                    let diagnostic = "game=\(game.id) network=\(game.broadcast) selectedID=\(selected?.id.description ?? "none") policy=college-ranked-evidence"
                    Logger(subsystem: "com.nulldev85.NullSports", category: "ChannelMatch").info("\(diagnostic, privacy: .public)")
                    continue
                }
                let signature = "\(game.league.rawValue)|\(game.awayTeam)|\(game.homeTeam)|\(game.broadcast)"
                guard !DailyCachePolicy.canReuseMatch(savedSignature: signatures[game.id],
                    currentSignature: signature, hasMatch: matches[game.id] != nil) else { continue }
                if let stream = Self.matchedStream(for: game, candidates: leagues[game.league] ?? [], searchText: searchText) {
                    matches[game.id] = stream
                    signatures[game.id] = signature
                } else {
                    matches.removeValue(forKey: game.id)
                    signatures.removeValue(forKey: game.id)
                }
                // Mirrors the college diagnostic above: a "no matching channel" report
                // should be readable from device logs without static code review.
                let diagnostic = "game=\(game.id) network=\(game.broadcast) selectedID=\(matches[game.id]?.id.description ?? "none") candidates=\((leagues[game.league] ?? []).count) policy=professional-signature-cache"
                Logger(subsystem: "com.nulldev85.NullSports", category: "ChannelMatch").info("\(diagnostic, privacy: .public)")
            }
            return (matches, signatures, matches != previousMatches)
        }.value
        guard DailyCachePolicy.shouldApplyRebuild(resultGeneration: generation, currentGeneration: matchGeneration,
            resultProfileID: profileID, currentProfileID: activeProfile?.id) else { return }
        if result.2 { gameStreamCache = result.0 }
        gameMatchSignatures = result.1
        let newIdentities = identities.filter { result.0[$0.key] != nil }
        let identityChanged = newIdentities != matchedGameIdentities
        matchedGameIdentities = newIdentities
        // Save changed matching results without rewriting the full guide on
        // every score/clock update. Writes remain serialized and atomic.
        if let profileID, force || result.2 || identityChanged || matchIdentities(now: now) != lastSavedMatchIdentities
            || lastSavedMatchDay.map({ !Calendar.current.isDate($0, inSameDayAs: now) }) != false {
            saveCache(profileID: profileID)
        }
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
        sportsIndexReady = false
        gameStreamCache = [:]
        gameMatchSignatures = [:]
        matchedGameIdentities = [:]
        lastSavedMatchIdentities = [:]
        lastSavedMatchDay = nil
        programsByChannel = [:]
        gamesByLeague = [:]
        scheduleLoadedLeagues = []
        scheduleDay = nil
        didRestoreSchedule = false
        scheduleErrorMessage = nil
        isScheduleLoading = false
        isGuideLoading = false
        isLoading = false
        guideUpdatedAt = nil
        libraryUpdatedAt = nil
        tomorrowScheduleUpdatedAt = nil
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
