import Foundation

@MainActor
final class SportsLibrary: ObservableObject {
    @Published private(set) var profiles: [XtreamProfile] = []
    @Published var activeProfile: XtreamProfile?
    @Published private(set) var categories: [XtreamCategory] = []
    @Published private(set) var streams: [XtreamStream] = []
    @Published private(set) var professionalStreams: [XtreamStream] = []
    @Published private(set) var programsByChannel: [String: [CurrentProgram]] = [:]
    @Published private(set) var gamesByLeague: [SportsLeague: [SportsGame]] = [:]
    @Published private(set) var isScheduleLoading = false
    @Published private(set) var isLoading = false
    @Published private(set) var isGuideLoading = false
    @Published var errorMessage: String?

    private let profilesKey = "NullSports.profiles"
    private let activeKey = "NullSports.activeProfile"
    private var eventCache: [SportsLeague: [ScheduledStream]] = [:]
    private var leagueStreamCache: [SportsLeague: [XtreamStream]] = [:]

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
        rebuildEventCache()
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

    func reload() async {
        guard let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return }
        isLoading = true
        errorMessage = nil
        do {
            let client = XtreamClient(profile: profile, password: password)
            async let loadedCategories = client.categories()
            async let loadedStreams = client.streams()
            categories = try await loadedCategories
            streams = try await loadedStreams
            rebuildProfessionalStreams()
            isLoading = false
            refreshSportsSchedule()
            refreshGuide(client: client, profileID: profile.id)
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
            self.rebuildProfessionalStreams()
            self.isGuideLoading = false
        }
    }

    func streams(for league: SportsLeague) -> [XtreamStream] {
        leagueStreamCache[league] ?? []
    }

    func liveEvents(for league: SportsLeague) -> [ScheduledStream] {
        (eventCache[league] ?? []).filter { $0.program.isLive }
    }

    func upcomingEvents(for league: SportsLeague) -> [ScheduledStream] {
        (eventCache[league] ?? []).filter { $0.program.start > Date() }
    }

    func games(for league: SportsLeague?) -> [SportsGame] {
        let games = league.map { gamesByLeague[$0] ?? [] } ?? SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }
        return games.filter { $0.isLive || $0.isUpcoming }.sorted { $0.start < $1.start }
    }

    private func refreshSportsSchedule() {
        isScheduleLoading = true
        Task { [weak self] in
            let games = await SportsScheduleClient().gamesToday()
            guard let self else { return }
            self.gamesByLeague = games
            self.isScheduleLoading = false
        }
    }

    func stream(for game: SportsGame) -> XtreamStream? {
        let candidates = streams(for: game.league)
        let away = game.awayTeam.lowercased()
        let home = game.homeTeam.lowercased()
        let awayNickname = away.split(separator: " ").last.map(String.init) ?? away
        let homeNickname = home.split(separator: " ").last.map(String.init) ?? home
        let broadcast = game.broadcast.lowercased()
        func score(_ stream: XtreamStream) -> Int {
            let guide = programs(for: stream).map { "\($0.title) \($0.detail)" }.joined(separator: " ").lowercased()
            let text = "\(stream.name.lowercased()) \(guide)"
            return (text.contains(away) ? 5 : 0) + (text.contains(home) ? 5 : 0)
                + (text.contains(awayNickname) ? 3 : 0) + (text.contains(homeNickname) ? 3 : 0)
                + (!broadcast.isEmpty && text.contains(broadcast) ? 4 : 0)
                + (text.contains(game.league.rawValue) ? 1 : 0)
        }
        let ranked = candidates.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 > 0 else { return nil }
        return best.0
    }

    func program(for stream: XtreamStream) -> CurrentProgram? {
        let listings = programs(for: stream)
        return listings.first(where: \.isLive) ?? listings.first
    }

    private func programs(for stream: XtreamStream) -> [CurrentProgram] {
        guard let channelID = stream.epgChannelID else { return [] }
        return programsByChannel[channelID] ?? []
    }

    private func rebuildEventCache() {
        var rebuilt = Dictionary(uniqueKeysWithValues: SportsLeague.allCases.map { ($0, [ScheduledStream]()) })
        for stream in professionalStreams {
            for program in programs(for: stream) {
                let listing = "\(program.title) \(program.detail)"
                let matchup = listing.localizedCaseInsensitiveContains(" vs ")
                    || listing.localizedCaseInsensitiveContains(" vs. ")
                    || listing.localizedCaseInsensitiveContains(" at ")
                guard matchup else { continue }
                for league in SportsLeague.allCases
                where leagueStreamCache[league, default: []].contains(stream)
                    && league.matchesProfessionalGame(listing) {
                    rebuilt[league, default: []].append(ScheduledStream(stream: stream, program: program))
                }
            }
        }
        eventCache = rebuilt.mapValues { $0.sorted { $0.program.start < $1.program.start } }
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
        eventCache = [:]
        programsByChannel = [:]
        gamesByLeague = [:]
        isScheduleLoading = false
        isGuideLoading = false
        persistProfiles()
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(activeProfile?.id.uuidString, forKey: activeKey)
    }
}
