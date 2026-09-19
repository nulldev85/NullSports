import Foundation
import OSLog

/// The one-file cache every install before this one wrote. Still read, once,
/// so an upgrade does not cost a viewer their channel list and a cold fetch;
/// it is split into the three below and deleted on the way past.
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

/// The channel list and what is built from it: everything the app needs before
/// it can put a row on screen, and a fraction of what the guide costs to read.
private struct ChannelCache: Codable, Sendable {
    let categories: [XtreamCategory]
    let streams: [XtreamStream]
    let sportsIndex: SportsIndex?
}

/// The guide. By far the largest of the three, and the last one needed, so it
/// is read after the channels are on screen rather than in front of them.
private struct GuideCache: Codable, Sendable {
    let programsByChannel: [String: [CurrentProgram]]
}

/// Everything small and everything volatile: when each half was fetched, the
/// digest of what the server sent for it, and today's matches.
///
/// This is the file that is written on every refresh, because these are the
/// things that change on every refresh. Keeping them here is what stops a new
/// timestamp from rewriting a channel list and a day of listings alongside it.
private struct LibraryState: Codable, Sendable {
    let guideUpdatedAt: Date?
    let libraryUpdatedAt: Date?
    let matchCacheVersion: Int?
    let dailyMatches: DailyGameMatches<XtreamStream>?
    let categoriesDigest: String?
    let streamsDigest: String?
    let guideDigest: String?
}

/// The channels worth offering, and which league each belongs to.
///
/// It used to carry a third field: a per-stream search string, each one a
/// channel name glued to its whole day of listings. Nothing ever read it. It
/// was built for every one of twenty-six thousand streams, held in memory,
/// written into the cache file and read back on the next launch, and no code
/// anywhere consulted it. An older cache file still has it; Codable ignores a
/// key the type no longer declares.
private struct SportsIndex: Codable, Sendable {
    let professional: [XtreamStream]
    let leagues: [SportsLeague: [XtreamStream]]
}

private struct ScheduleCache: Codable, Sendable {
    let savedAt: Date
    let games: [String: [SportsGame]]
}

/// The channel list and the state beside it: what has to be read before
/// anything can be drawn, and nothing else.
///
/// `guide` comes back filled only when the read had to fall back to the
/// one-file cache, which holds all three together -- there is no reading part
/// of that file, so having read it there is no sense in reading it again.
private struct RestoredLibrary: Sendable {
    let channels: ChannelCache
    let state: LibraryState?
    let guide: [String: [CurrentProgram]]?
}

@MainActor
final class SportsLibrary: ObservableObject {
    @Published private(set) var isSwitchingProfile = false
    private let profileDefaults: UserDefaults
    @Published private(set) var profiles: [XtreamProfile] = []
    @Published var activeProfile: XtreamProfile?
    @Published private(set) var categories: [XtreamCategory] = []
    @Published private(set) var streams: [XtreamStream] = []
    @Published private(set) var professionalStreams: [XtreamStream] = []
    @Published private(set) var programsByChannel: [String: [CurrentProgram]] = [:]
    @Published private(set) var favoriteStreamOrder: [Int] = []
    @Published private(set) var teamPreferences = TeamChannelPreferences()
    @Published private(set) var recentStreamOrder: [Int] = []
    @Published private(set) var gamesByLeague: [SportsLeague: [SportsGame]] = [:]
    @Published private(set) var scheduleLoadedLeagues: Set<SportsLeague> = []
    @Published private(set) var scheduleErrorMessage: String?
    @Published private(set) var isScheduleLoading = false
    @Published private(set) var isLoading = false
    @Published private(set) var isGuideLoading = false
    @Published var errorMessage: String?

    // Named for the app's old name on purpose: this is where existing installs
    // already keep their data, and renaming the key would hide it from them.
    private let profilesKey = "NullSports.profiles"
    private let activeKey = "NullSports.activeProfile"
    private let favoritesKey = "NullSports.favoriteStreams"
    private let teamPreferencesKey = "NullSports.teamChannelPreferences"
    private let recentsKey = "NullSports.recentChannels"
    private let scheduleKey = "NullSports.lastGoodSchedule"
    private var leagueStreamCache: [SportsLeague: [XtreamStream]] = [:]
    @Published private var sportsIndexReady = false
    @Published private var channelsValidatedThisSession = false
    @Published private var guideValidatedThisSession = false
    @Published private var scheduleValidatedLeagues: Set<SportsLeague> = []
    @Published private var gameStreamCache: [String: XtreamStream] = [:]
    @Published private var matchEvidenceScores: [String: Int] = [:]
    @Published private var didCompleteMatching = false
    // Same-day matches can be released before the large XMLTV download finishes,
    // after the fresh schedule and channel list confirm their inputs.
    @Published private var fastValidatedGameIDs: Set<String> = []
    private var restoredMatchGameIDs: Set<String> = []
    private var lastUnmatchedProviderRefresh: Date?
    private var gameMatchSignatures: [String: String] = [:]
    private var matchedGameIdentities: [String: [String]] = [:]
    private var indexGeneration = UUID()
    private var matchGeneration = UUID()
    private var guideListCache: (category: String?, favorites: Bool, recents: Bool, query: String, streams: [XtreamStream])?
    private var didRestoreSchedule = false
    private var scheduleDay: Date?
    private var bootstrapInFlight = false
    private var libraryRefreshInFlight = false
    @Published private var channelMatchingWorkCount = 0
    private var cacheWriteTask: Task<Void, Never>?
    private var guideRefresh: Task<Void, Never>?
    /// Discards the answer from a promote pass that a newer one has overtaken.
    private var promoteGeneration = UUID()
    /// Digests of what the server last sent for each list, carried across
    /// launches in the state file. A refresh that gets the same bytes back
    /// stops at the digest: nothing is decoded, compared, or written.
    private var categoriesDigest: String?
    private var streamsDigest: String?
    private var guideDigest: String?
    /// What is already on disk, so a write can be skipped when it would put
    /// back exactly what is there. Set when a file is read and when one is
    /// written; nil means "unknown", which writes.
    private var savedChannelsDigest: String?
    private var savedGuideDigest: String?
    /// Set when a one-file cache was read, cleared once the three files that
    /// replace it have been written.
    private var legacyCacheNeedsRetiring = false
    /// Set while a provider refresh is running *behind* restored cache. The
    /// screen stays usable, so this deliberately does not feed
    /// `channelsAreSyncing`, which gates playback and the picker.
    @Published private(set) var isRefreshingInBackground = false
    private var backgroundRefresh: Task<Void, Never>?
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

    init(profileDefaults: UserDefaults = .standard) {
        self.profileDefaults = profileDefaults
        if let data = profileDefaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([XtreamProfile].self, from: data) {
            profiles = decoded
        }
        if let id = profileDefaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:)) {
            activeProfile = profiles.first { $0.id == id }
        } else {
            activeProfile = profiles.first
        }
        if activeProfile == nil { activeProfile = profiles.first }
        // Claim legacy favorites once for the previously active provider.
        if let profile = activeProfile {
            let key = favoritesKey + "." + profile.id.uuidString
            if profileDefaults.object(forKey: key) == nil,
               let legacy = profileDefaults.array(forKey: favoritesKey) as? [Int] {
                profileDefaults.set(legacy, forKey: key)
            }
            profileDefaults.removeObject(forKey: favoritesKey)
        }
        restoreFavorites()
        restoreTeamPreferences()
        restoreRecentChannels()
    }

    var hasProfile: Bool { activeProfile != nil }

    // A rebuild no longer withdraws the matches already on screen: the first
    // completed pass is what makes them trustworthy, not the absence of work.
    var automaticMatchingReady: Bool {
        didCompleteMatching && channelsValidatedThisSession && guideValidatedThisSession && sportsIndexReady
    }

    private func matchIsReady(_ game: SportsGame) -> Bool {
        automaticMatchingReady || fastValidatedGameIDs.contains(game.id)
    }

    // Providers publish a game's own feed, and its guide entry, around first
    // pitch. That window is the only time refetching the lineup is likely to
    // turn an unmatched game into a matched one, and starting a little early
    // means the channel is ready when the game is rather than found afterwards.
    /// The provider's data is only as old as the older of its two halves: a
    /// fresh channel list cannot help while the guide that confirms the game is
    /// from this morning.
    private var providerFetchedAt: Date? {
        switch (libraryUpdatedAt, guideUpdatedAt) {
        case let (library?, guide?): return min(library, guide)
        case let (library?, nil): return library
        case let (nil, guide?): return guide
        case (nil, nil): return nil
        }
    }

    private var hasUnmatchedGameNeedingProviderData: Bool {
        let now = Date()
        let fetchedAt = providerFetchedAt
        return gamesByLeague.values.contains { games in
            games.contains { game in
                (game.isLive || game.isUpcoming) && gameStreamCache[game.id] == nil
                    && ProviderRefreshPolicy.needsRefresh(gameStart: game.start,
                        providerFetchedAt: fetchedAt, now: now)
            }
        }
    }

    // A channel's guide usually only names the game once it is under way, and a
    // scoreless opening gives the schedule nothing to change, so nothing asks
    // matching to look again. Retry rather than leave a live game unmatched.
    private var hasUnmatchedLiveGame: Bool {
        gamesByLeague.values.contains { games in
            games.contains { $0.isLive && gameStreamCache[$0.id] == nil }
        }
    }

    // Startup refreshes gate automatic matching; the Guide remains browsable.
    // Later score polling does not block already validated selections.
    var channelsAreSyncing: Bool {
        bootstrapInFlight || libraryRefreshInFlight || isGuideLoading || channelMatchingWorkCount > 0
            || (scheduleRefreshInFlight && scheduleValidatedLeagues.isEmpty)
    }

    /// When the channel list or the guide was last brought up to date,
    /// whichever is later. The values behind it are written during a reload,
    /// which also republishes the lists the Account card counts, so a card
    /// reading this redraws when it changes.
    var lastRefreshedAt: Date? {
        [libraryUpdatedAt, guideUpdatedAt].compactMap { $0 }.max()
    }

    /// True only for the first sync of a provider that has nothing cached — the
    /// one wait a viewer genuinely has to sit through. Repeat launches restore
    /// from disk and refresh behind the screen instead, which is the difference
    /// between "still syncing" and "already usable".
    var isInitialProviderSync: Bool {
        hasProfile && streams.isEmpty && channelsAreSyncing
    }

    /// Something usable came back from disk, so the screen need not wait.
    var hasRestoredCache: Bool { !streams.isEmpty }

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
        // Timed apart from the matching that follows it. One number for the
        // pair could not say which half was slow, and for two rounds it was
        // read as though it were all the matching's.
        let built = await StartupTrace.shared.measure("build sports index") {
            await Task.detached(priority: .utility) {
                Self.makeSportsIndex(categories: currentCategories, streams: currentStreams,
                                     programs: currentPrograms)
            }.value
        }
        let index = built.index
        for phase in built.phases {
            StartupTrace.shared.append("    " + phase.name, seconds: phase.seconds, detail: nil)
        }
        guard DailyCachePolicy.shouldApplyRebuild(resultGeneration: generation, currentGeneration: indexGeneration,
            resultProfileID: profileID, currentProfileID: activeProfile?.id) else { return }
        professionalStreams = index.professional
        leagueStreamCache = index.leagues
        sportsIndexReady = true
        let byLeague = SportsLeague.allCases
            .map { "\($0.rawValue) \(index.leagues[$0]?.count ?? 0)" }.joined(separator: ", ")
        StartupTrace.shared.note("index built",
                                 "\(index.professional.count) sports channels of \(currentStreams.count) — " + byLeague)
        await rebuildGameStreamCache(force: true)
    }

    /// The index, and how long each part of building it took.
    ///
    /// The timings come back rather than being recorded in place because this
    /// runs off the main actor, and because one number for the whole thing was
    /// read wrongly twice.
    nonisolated private static func makeSportsIndex(
        categories: [XtreamCategory], streams: [XtreamStream], programs: [String: [CurrentProgram]]
    ) -> (index: SportsIndex, phases: [(name: String, seconds: Double)]) {
        var phases: [(name: String, seconds: Double)] = []
        func time<T>(_ name: String, _ work: () -> T) -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let value = work()
            phases.append((name, ProcessInfo.processInfo.systemUptime - start))
            return value
        }

        let categoryNames = categories.reduce(into: [String: String]()) { $0[$1.id] = $1.categoryName }
        // Prepared once per guide channel rather than once per stream. A
        // provider lists the same channel several times over -- HD, FHD, SD,
        // a backup feed -- and every one of them points at these same listings.
        // Deliberately not prepared up front. Preparing all of them held a
        // word set for every guide channel at once -- five thousand days of
        // television, something like a hundred megabytes -- for the length of
        // the build, on a phone that is also holding twenty-six thousand
        // channels, a guide, and whatever the viewer is watching. Each one is
        // built where it is needed and dropped once it has answered, so one
        // exists at a time instead of five thousand.
        let blocked = ["radio", "audio", "sirius", "xm ", "music", "podcast", "fm ", "am ", "nfhs", "high school", "ncaab", "college basketball", "wnba"]
        let college = ["ncaa", "ncaaf", "college", "university", "acc network", "sec network", "big ten network", "big 12", "pac-12"]

        // Which leagues a guide channel's listings point at, worked out once
        // for the channel rather than once for every stream that carries it.
        //
        // This is the shape of the thing: five thousand guide channels behind
        // twenty-six thousand streams, and the answer for a channel's listings
        // is the same whichever stream is asking. It used to be recomputed per
        // stream, and then a second pass recomputed all of it again per
        // league. A day of television was scanned for thirty team names, over
        // and over, for an answer already known.
        var listingLeagues: [String: Set<SportsLeague>] = [:]
        var streamLeagues: [Int: Set<SportsLeague>] = [:]
        var collegeStreamIDs: Set<Int> = []

        func leagues(listedOn stream: XtreamStream) -> Set<SportsLeague> {
            guard let epgID = stream.epgChannelID, let listings = programs[epgID] else { return [] }
            if let known = listingLeagues[epgID] { return known }
            // Built here and gone at the end of this call. What is kept is the
            // answer: at most six league cases, against a day of listings.
            let text = SportsMatchText(
                alreadyLowercased: listings.map { "\($0.title) \($0.detail)" }
                    .joined(separator: " ").lowercased(),
                scannable: false)
            let found = Set(SportsLeague.allCases.filter { $0.matches(text) })
            listingLeagues[epgID] = found
            return found
        }

        let professional = time("channel filter") {
            streams.filter { stream in
                let category = categoryNames[stream.categoryID ?? ""] ?? ""
                let type = stream.streamType?.lowercased()
                guard type != "radio_streams", type != "radio" else { return false }
                let base = "\(stream.name) \(category)".lowercased()
                guard !blocked.contains(where: { base.contains($0) }) else { return false }
                if college.contains(where: { base.contains($0) }) { collegeStreamIDs.insert(stream.id) }
                // Short: a name and a category, and already lowercase.
                let baseText = SportsMatchText(alreadyLowercased: base)
                let found = Set(SportsLeague.allCases.filter { $0.matches(baseText) })
                    .union(leagues(listedOn: stream))
                guard !found.isEmpty else { return false }
                streamLeagues[stream.id] = found
                return true
            }
        }
        // No matching happens here any more. The filter above already settled
        // which leagues each channel belongs to; this only sorts them.
        let leagueBuckets = time("league buckets") {
            Dictionary(uniqueKeysWithValues: SportsLeague.allCases.map { league in
                (league, professional.filter { stream in
                    guard league == .ncaaf || !collegeStreamIDs.contains(stream.id) else { return false }
                    return streamLeagues[stream.id]?.contains(league) ?? false
                })
            })
        }
        return (SportsIndex(professional: professional, leagues: leagueBuckets), phases)
    }

    func addProfile(name: String, serverURL: String, username: String, password: String) async -> Bool {
        let profile = XtreamProfile(name: name.isEmpty ? "My IPTV" : name, serverURL: serverURL, username: username)
        do {
            let client = XtreamClient(profile: profile, password: password)
            let envelope = try await client.authenticate()
            guard envelope.userInfo?.auth == 1 else { throw XtreamClient.XtreamError.unauthorized }
            try KeychainStore.save(password: password, profileID: profile.id)
            profiles.append(profile)
            // Additional providers are saved without interrupting the current one.
            let isFirstProfile = activeProfile == nil
            if isFirstProfile {
                activeProfile = profile
                restoreFavorites()
                restoreTeamPreferences()
                restoreRecentChannels()
            }
            persistProfiles()
            if isFirstProfile { await reload() }
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
        let trace = StartupTrace.shared
        if streams.isEmpty {
            trace.begin()
            trace.note("cold start", "no channels in memory")
        }
        if streams.isEmpty,
           let restored = await trace.measure("read cache: channels + state",
                                              { await Self.readHead(profileID: profile.id) }) {
            guard activeProfile?.id == profile.id else { return }
            // The channel list goes up first. Every screen in the app needs it
            // and nothing needs it sooner, and it is a fraction of the size of
            // the guide that used to be decoded in front of it.
            categories = restored.channels.categories
            streams = restored.channels.streams
            guideListCache = nil
            let state = restored.state
            guideUpdatedAt = state?.guideUpdatedAt
            libraryUpdatedAt = state?.libraryUpdatedAt
            categoriesDigest = state?.categoriesDigest
            streamsDigest = state?.streamsDigest
            guideDigest = state?.guideDigest
            // Now the expensive half, with something already on screen. The
            // index and the matching below both read it, so it has to be in
            // place before either of them runs -- but not before the channels
            // are, which is the whole change.
            trace.note("channels on screen", "\(streams.count) channels, \(categories.count) categories")
            if let carried = restored.guide {
                legacyCacheNeedsRetiring = true
                programsByChannel = carried
                trace.note("read cache: guide", "from the one-file cache, being migrated")
            } else {
                // Channels are on screen and the guide is not yet, which is a
                // state the app already has a word for. Saying it stops the
                // Guide printing "No listing" against every row for as long as
                // the read takes -- an empty guide and a guide still being
                // read look identical from a row, and only one of them is
                // worth telling anyone about.
                isGuideLoading = true
                let guide = await trace.measure("read cache: guide",
                                                { await Self.readGuide(profileID: profile.id) })
                guard activeProfile?.id == profile.id else {
                    isGuideLoading = false
                    return
                }
                if let guide { programsByChannel = guide }
                isGuideLoading = false
                trace.note("guide on screen", "\(programsByChannel.count) channels with listings")
            }
            guideListCache = nil
            savedChannelsDigest = channelsSignature
            savedGuideDigest = guideSignature
            let now = Date()
            if state?.matchCacheVersion == 2, let saved = state?.dailyMatches {
                gameStreamCache = saved.restore(identities: matchIdentities(now: now), available: streams, now: now)
                restoredMatchGameIDs = Set(gameStreamCache.keys)
                matchedGameIdentities = saved.identities.filter { gameStreamCache[$0.key] != nil }
                lastSavedMatchIdentities = saved.identities
                lastSavedMatchDay = saved.savedAt
                // Preserve the existing professional matching policy's signatures.
                for game in gamesByLeague.values.flatMap({ $0 }) where game.league != .ncaaf && gameStreamCache[game.id] != nil {
                    gameMatchSignatures[game.id] = "\(game.league.rawValue)|\(game.awayTeam)|\(game.homeTeam)|\(game.broadcast)"
                }
            }
            // The index is a function of the channel list and the guide, and
            // neither of those is a function of what day it is. It used to be
            // gated on the saved *matches* being from today, which threw a
            // perfectly good index away on the first launch of every new day
            // and spent a minute building an identical one. The matches keep
            // their daily gate above, where it belongs; a refresh rebuilds the
            // index whenever either of its inputs actually changes.
            if let index = restored.channels.sportsIndex,
               DailyCachePolicy.hasCompleteIndex(savedLeagues: Set(index.leagues.keys.map(\.rawValue)),
                   expectedLeagues: Set(SportsLeague.allCases.map(\.rawValue))) {
                professionalStreams = index.professional
                leagueStreamCache = index.leagues
                sportsIndexReady = true
                trace.note("sports index restored", "from cache")
                if matchIdentities(now: now).keys.contains(where: { gameStreamCache[$0] == nil }) {
                    await trace.measure("rematch games", { await rebuildGameStreamCache() })
                }
            } else {
                // Say which of the two it was. "Missing or stale" covered a
                // file that was not there, an index that did not cover every
                // league, and a state file that never arrived -- and guessing
                // between them cost a round of testing.
                let why: String
                if restored.channels.sportsIndex == nil {
                    why = state == nil
                        ? "no index in the cache, and no state file either"
                        : "no index in the cache"
                } else {
                    why = "index in the cache does not cover every league"
                }
                await trace.measure("rebuild sports index", detail: why,
                                    { await rebuildProfessionalStreams() })
            }
        }
        guard activeProfile?.id == profile.id else { return }
        // Cached rows may render immediately; playback waits for fresh evidence.
        refreshSchedule(showsLoading: false)
        // Providers recycle numbered event stream IDs. Same-day disk data is
        // useful for browsing, but cannot authorize playback before a fresh fetch.
        if channelsValidatedThisSession && guideValidatedThisSession && isLibraryFresh && isGuideFresh { return }
        // With nothing restored there is nothing to show, so the first sync is
        // awaited and reported. With cache on screen the same refresh runs
        // behind it: the Live screen, the Guide, favorites, recent channels and
        // saved preferences are all usable while it runs, and matching
        // re-verifies itself when it lands — accuracy unchanged, wait removed.
        guard streams.isEmpty else {
            refreshInBackground()
            return
        }
        await refreshLibrary(forceGuide: true, refreshChannels: true)
    }

    private func refreshInBackground() {
        guard backgroundRefresh == nil, let profileID = activeProfile?.id else { return }
        isRefreshingInBackground = true
        backgroundRefresh = Task { [weak self] in
            await self?.refreshLibrary(forceGuide: true, refreshChannels: true)
            guard let self, self.activeProfile?.id == profileID else { return }
            self.isRefreshingInBackground = false
            self.backgroundRefresh = nil
        }
    }

    func reload() async {
        guard !isSwitchingProfile else { return }
        refreshSchedule()
        await refreshLibrary(forceGuide: true)
    }

    // `invalidatesSession` is what makes startup withhold playback until a fetch
    // has happened this session, because providers recycle numbered event stream
    // IDs. A later top-up is replacing already validated data rather than waiting
    // for its first fetch, so it leaves that gate alone and keeps the matches up.
    private func refreshLibrary(forceGuide: Bool, refreshChannels: Bool = true,
                                invalidatesSession: Bool = true) async {
        guard !libraryRefreshInFlight,
              let profile = activeProfile, let password = KeychainStore.password(profileID: profile.id) else { return }
        libraryRefreshInFlight = true
        defer { libraryRefreshInFlight = false }
        if refreshChannels && invalidatesSession {
            channelsValidatedThisSession = false
            fastValidatedGameIDs = []
        }
        if forceGuide && invalidatesSession { guideValidatedThisSession = false }
        isLoading = refreshChannels && streams.isEmpty
        errorMessage = nil
        let client = XtreamClient(profile: profile, password: password)
        if forceGuide { refreshGuide(client: client, profileID: profile.id) }
        guard refreshChannels else { return }
        do {
            // nil back means the server sent the same bytes as last time, so
            // there is nothing to decode and nothing to compare -- which on a
            // provider with tens of thousands of channels is most of what a
            // refresh used to do. The policy decides whether the app has
            // earned the right to ask that cheap question at all.
            let trace = StartupTrace.shared
            let answers = try await trace.measure("fetch channel list") {
                async let loadedCategories = client.categories(
                    ifChangedFrom: LibraryCachePolicy.digest(categoriesDigest,
                                                             whenHolding: !categories.isEmpty))
                async let loadedStreams = client.streams(
                    ifChangedFrom: LibraryCachePolicy.digest(streamsDigest,
                                                             whenHolding: !streams.isEmpty))
                return try await (loadedCategories, loadedStreams)
            }
            let (freshCategories, freshStreams) = answers
            // The digest saves parsing these, never downloading them, so the
            // size is recorded either way -- it is the number that says
            // whether the next thing worth doing is at the HTTP level.
            trace.note("channel list downloaded",
                       "\(StartupTrace.size(freshCategories.bytes + freshStreams.bytes)), "
                       + (freshStreams.payload == nil ? "unchanged" : "changed"))
            guard activeProfile?.id == profile.id else { return }
            // Different bytes still need the old comparison: a server can
            // reorder a list, or restate it, without changing what it says.
            let oldCategories = categories
            let oldStreams = streams
            let newCategories = freshCategories.payload
            let newStreams = freshStreams.payload
            let changes = await trace.measure("compare channel list") {
                await Task.detached(priority: .utility) {
                    (newCategories.map { $0.value != oldCategories } ?? false,
                     newStreams.map { $0.value != oldStreams } ?? false)
                }.value
            }
            guard activeProfile?.id == profile.id else { return }
            if let newCategories { categoriesDigest = newCategories.digest }
            if let newStreams { streamsDigest = newStreams.digest }
            if changes.0, let newCategories { categories = newCategories.value }
            if changes.1, let newStreams {
                guideListCache = nil
                streams = newStreams.value
            }
            libraryUpdatedAt = Date()
            // Rebuilt here, on the channel list alone, and again when the guide
            // lands. That is one build more than it needs.
            //
            // Waiting for the guide first would fix it, and I tried: the app
            // froze. `libraryRefreshInFlight` is held for the whole of this
            // function, and it feeds `channelsAreSyncing`, which disables the
            // channel picker and withholds playback until a refresh has
            // finished. Waiting on a ninety-six megabyte download before
            // releasing that is not an optimisation, it is a stall with the
            // controls switched off.
            //
            // Saving the second build means moving it off this function's
            // in-flight window entirely, not extending the window.
            if changes.0 || changes.1 {
                await trace.measure("rebuild sports index", detail: "channel list changed",
                                    { await rebuildProfessionalStreams() })
            }
            guard activeProfile?.id == profile.id else { return }
            channelsValidatedThisSession = true
            await promoteCachedMatchesIfSafe()
            isLoading = false
            saveCache(profileID: profile.id)
        } catch {
            guard activeProfile?.id == profile.id else { return }
            isLoading = false
            if streams.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Returns the task doing the work, so a caller that is about to rebuild
    /// the index can wait for the guide first.
    ///
    /// The channel list and the guide arrive seconds apart, and each used to
    /// rebuild the index on arrival: two full builds per launch, the first of
    /// them thrown away by the generation token the moment the second landed.
    @discardableResult
    private func refreshGuide(client: XtreamClient, profileID: UUID) -> Task<Void, Never>? {
        guard !isGuideLoading else { return nil }
        isGuideLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeProfile?.id == profileID { self.isGuideLoading = false }
            }
            // Keep the last good guide and its timestamp when a refresh fails.
            // A thrown error and an unchanged guide are different answers: the
            // first leaves the timestamp alone, the second moves it on, because
            // the server did answer and it said nothing has changed.
            let trace = StartupTrace.shared
            let answer: XtreamAnswer<[String: [CurrentProgram]]>
            // As above: an empty guide cannot be left unchanged.
            let ask = LibraryCachePolicy.digest(self.guideDigest,
                                                whenHolding: !self.programsByChannel.isEmpty)
            do {
                // This covers the download and, when the bytes are new, the
                // XMLTV parse. Two very different costs, so the note below
                // says which one was paid.
                answer = try await trace.measure("fetch guide") {
                    try await client.programsToday(ifChangedFrom: ask)
                }
            } catch { return }
            trace.note("guide downloaded",
                       "\(StartupTrace.size(answer.bytes)), "
                       + (answer.payload == nil ? "unchanged — not parsed" : "parsed"))
            guard self.activeProfile?.id == profileID else { return }
            var changed = false
            if let fresh = answer.payload {
                let previousPrograms = self.programsByChannel
                let programs = fresh.value
                changed = await trace.measure("compare guide") {
                    await Task.detached(priority: .utility) { previousPrograms != programs }.value
                }
                guard self.activeProfile?.id == profileID else { return }
                self.guideDigest = fresh.digest
                if changed { self.programsByChannel = programs }
            }
            self.guideUpdatedAt = Date()
            if changed {
                await trace.measure("rebuild sports index", detail: "guide changed",
                                    { await self.rebuildProfessionalStreams() })
            }
            guard self.activeProfile?.id == profileID else { return }
            self.guideValidatedThisSession = true
            self.saveCache(profileID: profileID)
        }
        guideRefresh = task
        return task
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

    private var channelsSignature: String {
        LibraryCachePolicy.channelsSignature(categoriesDigest: categoriesDigest,
                                             streamsDigest: streamsDigest,
                                             guideDigest: guideDigest,
                                             hasIndex: sportsIndexReady)
    }

    private var guideSignature: String {
        LibraryCachePolicy.guideSignature(guideDigest: guideDigest)
    }

    private func saveCache(profileID: UUID) {
        let now = Date()
        let identities = matchIdentities(now: now)
        // Always written: every one of these changes on every refresh, which
        // is the whole reason they were moved out of the big files.
        let state = LibraryState(
            guideUpdatedAt: guideUpdatedAt,
            libraryUpdatedAt: libraryUpdatedAt,
            matchCacheVersion: 2,
            dailyMatches: DailyGameMatches(savedAt: now, identities: matchedGameIdentities,
                channels: gameStreamCache.filter { key, _ in
                    identities[key] != nil && identities[key] == matchedGameIdentities[key]
                }),
            categoriesDigest: categoriesDigest,
            streamsDigest: streamsDigest,
            guideDigest: guideDigest
        )
        lastSavedMatchIdentities = identities
        lastSavedMatchDay = now

        // Written only when they would say something new.
        let channels: ChannelCache? = !LibraryCachePolicy.needsWriting(
            signature: channelsSignature, lastWritten: savedChannelsDigest) ? nil : ChannelCache(
            categories: categories,
            streams: streams,
            sportsIndex: sportsIndexReady
                ? SportsIndex(professional: professionalStreams, leagues: leagueStreamCache)
                : nil
        )
        let guide: GuideCache? = LibraryCachePolicy.needsWriting(
            signature: guideSignature, lastWritten: savedGuideDigest)
            ? GuideCache(programsByChannel: programsByChannel) : nil
        savedChannelsDigest = channelsSignature
        savedGuideDigest = guideSignature
        let retireLegacy = legacyCacheNeedsRetiring
        legacyCacheNeedsRetiring = false

        let previousWrite = cacheWriteTask
        cacheWriteTask = Task.detached(priority: .utility) {
            await previousWrite?.value
            if let channels { Self.write(channels, to: Self.channelsURL(profileID: profileID)) }
            if let guide { Self.write(guide, to: Self.guideURL(profileID: profileID)) }
            Self.write(state, to: Self.stateURL(profileID: profileID))
            // Only once the three that replace it are on disk.
            if retireLegacy {
                try? FileManager.default.removeItem(at: Self.cacheURL(profileID: profileID))
            }
        }
    }

    nonisolated private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func readHead(profileID: UUID) async -> RestoredLibrary? {
        await Task.detached(priority: .utility) {
            let decoder = JSONDecoder()
            if let data = try? Data(contentsOf: channelsURL(profileID: profileID)),
               let channels = try? decoder.decode(ChannelCache.self, from: data) {
                let state = (try? Data(contentsOf: stateURL(profileID: profileID)))
                    .flatMap { try? decoder.decode(LibraryState.self, from: $0) }
                return RestoredLibrary(channels: channels, state: state, guide: nil)
            }
            guard let data = try? Data(contentsOf: cacheURL(profileID: profileID)),
                  let legacy = try? decoder.decode(LibraryCache.self, from: data) else { return nil }
            return RestoredLibrary(
                channels: ChannelCache(categories: legacy.categories, streams: legacy.streams,
                                       sportsIndex: legacy.sportsIndex),
                state: LibraryState(guideUpdatedAt: legacy.guideUpdatedAt,
                                    libraryUpdatedAt: legacy.libraryUpdatedAt,
                                    matchCacheVersion: legacy.matchCacheVersion,
                                    dailyMatches: legacy.dailyMatches,
                                    // A one-file cache predates digests, so the
                                    // next refresh fetches and compares as it
                                    // always did, and records them for the one
                                    // after that.
                                    categoriesDigest: nil, streamsDigest: nil, guideDigest: nil),
                guide: legacy.programsByChannel
            )
        }.value
    }

    nonisolated private static func readGuide(profileID: UUID) async -> [String: [CurrentProgram]]? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: guideURL(profileID: profileID)),
                  let guide = try? JSONDecoder().decode(GuideCache.self, from: data) else { return nil }
            return guide.programsByChannel
        }.value
    }

    nonisolated private static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// The one-file cache written by every version before the split.
    nonisolated private static func cacheURL(profileID: UUID) -> URL {
        cacheDirectory().appendingPathComponent("lineup-\(profileID.uuidString).json")
    }

    nonisolated private static func channelsURL(profileID: UUID) -> URL {
        cacheDirectory().appendingPathComponent("lineup-\(profileID.uuidString)-channels.json")
    }

    nonisolated private static func guideURL(profileID: UUID) -> URL {
        cacheDirectory().appendingPathComponent("lineup-\(profileID.uuidString)-guide.json")
    }

    nonisolated private static func stateURL(profileID: UUID) -> URL {
        cacheDirectory().appendingPathComponent("lineup-\(profileID.uuidString)-state.json")
    }

    nonisolated private static func removeCaches(profileID: UUID) {
        let manager = FileManager.default
        for url in [cacheURL(profileID: profileID), channelsURL(profileID: profileID),
                    guideURL(profileID: profileID), stateURL(profileID: profileID)] {
            try? manager.removeItem(at: url)
        }
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
        guard !isSwitchingProfile else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if scheduleDay != today {
            scheduleDay = today
            gamesByLeague = [:]
            scheduleLoadedLeagues = []
            scheduleValidatedLeagues = []
            gameStreamCache = [:]
            matchEvidenceScores = [:]
            didCompleteMatching = false
            fastValidatedGameIDs = []
            restoredMatchGameIDs = []
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
            // Failed or partial fetches must remain eligible for the next poll.
            // A successful empty slate still has all leagues marked as loaded.
            if fetchesTomorrow {
                let succeeded = snapshot.errorMessage == nil
                    && snapshot.loadedLeagues == Set(SportsLeague.allCases)
                self.tomorrowScheduleUpdatedAt = succeeded ? Date() : nil
            }
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
                }
                if update.1 || self.hasUnmatchedLiveGame {
                    await self.rebuildGameStreamCache()
                }
                if self.hasUnmatchedGameNeedingProviderData,
                   Date().timeIntervalSince(self.lastUnmatchedProviderRefresh ?? .distantPast) > 120 {
                    self.lastUnmatchedProviderRefresh = Date()
                    await self.refreshLibrary(forceGuide: true, refreshChannels: true, invalidatesSession: false)
                }
                guard self.activeProfile?.id == profileID else { return }
                self.scheduleValidatedLeagues.formUnion(snapshot.loadedLeagues)
                await self.promoteCachedMatchesIfSafe()
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
        matchIsReady(game) && scheduleValidatedLeagues.contains(game.league) ? gameStreamCache[game.id] : nil
    }

    // Which rule authorized a match, for the diagnostics screen. A wrong game
    // should be able to name the evidence behind it without a device log.
    enum MatchEvidence: String {
        case dedicatedFeed = "Channel is named for this game"
        case guideListing = "Guide listing named both teams"
        case networkOnly = "Network only, no game evidence"
    }

    // The two matchers score on different scales, so the league decides how a
    // score reads: college ranks guide evidence highest, while the professional
    // policy ranks a channel named for the game above a national channel's guide.
    enum MatchRejection: String {
        case scheduleChanged = "Matched, but the schedule moved since — a tap opens the picker"
        case noLongerShowing = "Matched, but the channel no longer shows this game — a tap opens the picker"
    }

    // Playback asks verifiedStream, which revalidates; the rows ask stream(for:),
    // which does not. A diagnostics row reporting the cheap answer could promise a
    // channel that a tap then refuses, so it reports the disagreement instead.
    func playbackRejection(for game: SportsGame) -> MatchRejection? {
        guard stream(for: game) != nil, verifiedStream(for: game) == nil else { return nil }
        return matchedGameIdentities[game.id] == Self.matchIdentity(game) ? .noLongerShowing : .scheduleChanged
    }

    func matchEvidence(for game: SportsGame) -> MatchEvidence? {
        guard let score = matchEvidenceScores[game.id] else { return nil }
        guard game.league == .ncaaf else { return score >= 400 ? .dedicatedFeed : .guideListing }
        if score >= 300 { return .guideListing }
        return score >= 200 ? .dedicatedFeed : .networkOnly
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
         game.eventName ?? "",
         String(game.start.timeIntervalSince1970)]
    }

    // Only playback actions revalidate. Row rendering must remain a cheap lookup.
    func verifiedStream(for game: SportsGame) -> XtreamStream? {
        guard matchIsReady(game), scheduleValidatedLeagues.contains(game.league),
              let stream = gameStreamCache[game.id],
              matchedGameIdentities[game.id] == Self.matchIdentity(game) else { return nil }
        guard Self.carriesGame(stream, game: game, listings: programs(for: stream), now: Date()) else { return nil }
        return stream
    }

    /// Does current evidence say this channel is carrying this game?
    ///
    /// The single question behind every automatic playback decision. Lineup's
    /// own match asks it through `verifiedStream(for:)`, a saved team preference
    /// asks it before being honoured, and failover asks it before adding a
    /// channel to its plan — all with the same rules, so a preference can never
    /// take a weaker path to playback than an automatic match would.
    func isStream(_ stream: XtreamStream, verifiedFor game: SportsGame) -> Bool {
        guard matchIsReady(game), scheduleValidatedLeagues.contains(game.league) else { return false }
        return Self.carriesGame(stream, game: game, listings: programs(for: stream), now: Date())
    }

    /// The viewer's saved channel for either team, but only when evidence says
    /// it is carrying this game. A regional network that exists all season is
    /// not thereby showing tonight's nationally exclusive game.
    func verifiedPreferredStream(for game: SportsGame) -> XtreamStream? {
        for side in preferenceSides(for: game) {
            guard let saved = teamPreferences.preference(for: side.key),
                  let stream = stream(withID: saved.streamID),
                  isStream(stream, verifiedFor: game) else { continue }
            return stream
        }
        return nil
    }

    // Revalidated at selection time even if a score refresh had no changes. The
    // network a game is scheduled on is not evidence that a channel is carrying
    // it, so it cannot authorize playback on its own; a game left unmatched
    // opens the channel picker instead of playing a guess. College keeps its
    // own stricter policy, including the network-fallback refusal.
    nonisolated private static func carriesGame(_ stream: XtreamStream, game: SportsGame,
                                                listings: [CurrentProgram], now: Date) -> Bool {
        if game.league == .ncaaf {
            return CollegeChannelMatcher.score(channel: stream.name,
                listings: Self.collegeListings(listings),
                game: Self.collegeMatchup(game), now: now,
                allowNetworkFallback: false) != nil
        }
        return Self.professionalScore(
            stream, game: game, preparedGame: Self.prepared(game),
            channel: ProfessionalChannelMatcher.prepare(
                channel: stream.name, listings: Self.matcherListings(["": listings])[""] ?? []),
            listings: listings, now: now) != nil
    }

    nonisolated private static func collegeMatchup(_ game: SportsGame) -> CollegeChannelMatcher.Matchup {
        .init(broadcast: game.broadcast, away: game.awayTeam, home: game.homeTeam,
              awayAbbreviation: game.awayAbbreviation, homeAbbreviation: game.homeAbbreviation,
              kickoff: game.start, isLive: game.isLive, status: game.status)
    }

    nonisolated private static func collegeListings(_ programs: [CurrentProgram]) -> [CollegeChannelMatcher.Listing] {
        programs.map { .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end) }
    }

    /// The matcher's own view of a channel's listings, built once per channel.
    ///
    /// This used to be built inside the score, which is called for every
    /// candidate channel of every game -- sixty-six games against five
    /// thousand channels is three hundred thousand times, each one rebuilding
    /// the same array of the same listings for the same channel.
    nonisolated private static func matcherListings(
        _ programs: [String: [CurrentProgram]]
    ) -> [String: [ProfessionalChannelMatcher.PreparedListing]] {
        programs.mapValues { listings in
            ProfessionalChannelMatcher.prepare(
                listings.map { .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end) })
        }
    }

    nonisolated private static func prepared(_ game: SportsGame) -> ProfessionalChannelMatcher.PreparedGame {
        ProfessionalChannelMatcher.prepare(
            .init(away: game.awayTeam, home: game.homeTeam,
                  awayAbbreviation: game.awayAbbreviation, homeAbbreviation: game.homeAbbreviation,
                  start: game.start, isLive: game.isLive))
    }

    nonisolated private static func professionalScore(_ stream: XtreamStream, game: SportsGame,
                                                       preparedGame: ProfessionalChannelMatcher.PreparedGame,
                                                       channel: ProfessionalChannelMatcher.PreparedChannel,
                                                       listings: [CurrentProgram],
                                                       now: Date) -> Int? {
        guard game.isLive || game.isUpcoming else { return nil }
        if game.league == .ufc {
            return ufcScore(channel: stream.name, listings: listings, game: game, now: now)
        }
        return ProfessionalChannelMatcher.score(channel: channel, game: preparedGame, now: now)
    }

    /// Every candidate channel prepared once for the pass: its name normalized
    /// and padded, its listings likewise, and whether it is a replay or a
    /// whip-around feed already decided.
    nonisolated private static func preparedChannels(
        _ candidates: [XtreamStream],
        listings: [String: [ProfessionalChannelMatcher.PreparedListing]]
    ) -> [Int: ProfessionalChannelMatcher.PreparedChannel] {
        var prepared: [Int: ProfessionalChannelMatcher.PreparedChannel] = [:]
        for candidate in candidates where prepared[candidate.id] == nil {
            prepared[candidate.id] = ProfessionalChannelMatcher.prepare(
                channel: candidate.name, listings: listings[candidate.epgChannelID ?? ""] ?? [])
        }
        return prepared
    }

    nonisolated private static func ufcScore(channel: String, listings: [CurrentProgram],
                                              game: SportsGame, now: Date) -> Int? {
        func normalized(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        func contains(_ text: String, _ phrase: String) -> Bool {
            !phrase.isEmpty && (" " + text + " ").contains(" " + phrase + " ")
        }
        let name = normalized(channel)
        guard !["replay", "classic", "highlights", "radio", "audio"].contains(where: { contains(name, $0) }) else { return nil }
        let away = normalized(game.awayTeam).split(separator: " ").last.map(String.init) ?? ""
        let home = normalized(game.homeTeam).split(separator: " ").last.map(String.init) ?? ""
        let card = normalized(game.eventName ?? "")
        let cardParts = card.split(separator: " ")
        let numberedCard = cardParts.count > 1 && cardParts[0] == "ufc" && Int(cardParts[1]) != nil
            ? "ufc " + cardParts[1] : ""
        func identifiesCard(_ text: String) -> Bool {
            (contains(text, away) && contains(text, home))
                || (!numberedCard.isEmpty && contains(text, numberedCard))
        }
        let point = game.isLive ? now : game.start
        let current = listings.filter { $0.start <= point && point < $0.end }
        let listingConfirms = current.contains {
            identifiesCard(normalized($0.title + " " + $0.detail))
                && $0.start <= game.start.addingTimeInterval(60 * 60) && $0.end > game.start
        }
        let guideSilent = current.isEmpty || current.allSatisfy {
            let title = normalized($0.title)
            return ["", "live", "ufc", "mma", "pay per view", "ppv", "no program information"].contains(title)
                && normalized($0.detail).isEmpty
        }
        if identifiesCard(name) && (listingConfirms || guideSilent) { return 400 }
        return listingConfirms ? 300 : nil
    }

    nonisolated private static func matchedStream(for game: SportsGame, candidates: [XtreamStream],
                                                  programs: [String: [CurrentProgram]],
                                                  channels: [Int: ProfessionalChannelMatcher.PreparedChannel],
                                                  preparedGame: ProfessionalChannelMatcher.PreparedGame,
                                                  now: Date) -> XtreamStream? {
        var best: (stream: XtreamStream, score: Int)?
        for candidate in candidates {
            guard let prepared = channels[candidate.id] else { continue }
            guard let score = professionalScore(candidate, game: game, preparedGame: preparedGame,
                channel: prepared, listings: programs[candidate.epgChannelID ?? ""] ?? [],
                now: now) else { continue }
            if let current = best {
                guard score > current.score || (score == current.score && candidate.id < current.stream.id) else { continue }
            }
            best = (candidate, score)
        }
        return best?.stream
    }

    /// Match today's games to channels.
    ///
    /// Several things ask for this at once on a launch: the restored index, a
    /// schedule arriving, a finished refresh, a score poll. I tried queueing
    /// them -- one pass at a time, one more behind it -- and made the launch
    /// twice as slow: four passes that had been overlapping at twenty seconds
    /// each, for twenty-two seconds of wall clock between them, became four
    /// runs end to end for eighty-five. Queueing was the wrong lever. They
    /// overlap again, and the generation token throws away whichever results
    /// arrive stale, as it always did.
    ///
    /// The cost worth removing is inside a single pass, not in how many of
    /// them there are.
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
        // Listings that have already finished are kept now, because the Guide
        // draws an hour of history and cannot show what was thrown away. The
        // matchers were never given them: the parser used to drop them before
        // anything saw them, and a matcher handed a listing that ended an hour
        // ago can credit a channel for a game that is no longer on it. Matching
        // sees exactly what it always saw.
        let matchNow = Date()
        let trace = StartupTrace.shared
        // Every listing of every channel, copied and filtered, before the
        // matching has started. Measured on its own because "rematch games"
        // as one number cannot say whether the cost is this or the matching.
        let listings = programsByChannel
        let programs = await trace.measure("prepare listings for matching") {
            await Task.detached(priority: .utility) {
                listings.mapValues { $0.filter { $0.end > matchNow } }
            }.value
        }
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
        let result = await trace.measure("match games to channels",
                                         detail: "\(games.count) games, \(leagues.values.map(\.count).reduce(0, +)) league candidates") {
            await Task.detached(priority: .utility) {
            // Timed in two halves. The detail above counts only the league
            // buckets, and four rounds of tuning went into the half they
            // describe while the other half -- college, which casts its net
            // over every channel the provider has -- went unmeasured.
            var collegeSeconds = 0.0
            var professionalSeconds = 0.0
            func clock() -> Double { ProcessInfo.processInfo.systemUptime }
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
            // Built once for the whole pass, rather than rebuilt inside every
            // one of three hundred thousand scores.
            let preparedListings = Self.matcherListings(programs)
            // Every candidate channel's name, normalized once for the pass
            // rather than once for each of sixty-six games.
            let preparedChannels = Self.preparedChannels(leagues.values.flatMap { $0 },
                                                         listings: preparedListings)
            let activeIDs = Set(games.map(\.id))
            var matches = previousMatches.filter { activeIDs.contains($0.key) }
            var signatures = previousSignatures.filter { activeIDs.contains($0.key) }
            var evidenceByGame: [String: Int] = [:]
            for game in games {
                if game.league == .ncaaf {
                    guard game.isLive || game.isUpcoming else { matches[game.id] = nil; continue }
                    let collegeStart = clock()
                    defer { collegeSeconds += clock() - collegeStart }
                    let matchup = Self.collegeMatchup(game)
                    let selectedID = CollegeChannelMatcher.select(collegeCandidates, game: matchup, now: now,
                        allowNetworkFallback: false)
                    let selected = selectedID.flatMap { id in collegeStreams.first { $0.id == id } }
                    matches[game.id] = selected
                    // The evidence tier that authorized the match: a wrong game names
                    // the rule that approved it without reading the matcher's source.
                    let evidence = selected.flatMap {
                        CollegeChannelMatcher.score(channel: $0.name,
                            listings: collegePrograms[$0.epgChannelID ?? ""] ?? [],
                            game: matchup, now: now, allowNetworkFallback: false)
                    }
                    evidenceByGame[game.id] = evidence
                    let diagnostic = "game=\(game.id) network=\(game.broadcast) selectedID=\(selected?.id.description ?? "none") evidence=\(evidence?.description ?? "none") policy=college-ranked-evidence"
                    Logger(subsystem: "com.nulldev85.NullSports", category: "ChannelMatch").info("\(diagnostic, privacy: .public)")
                    continue
                }
                let professionalStart = clock()
                defer { professionalSeconds += clock() - professionalStart }
                // Worked out once for this game, not once per candidate.
                let preparedGame = Self.prepared(game)
                let signature = "\(game.league.rawValue)|\(game.awayTeam)|\(game.homeTeam)|\(game.broadcast)"
                let reused: (stream: XtreamStream, evidence: Int)? = DailyCachePolicy.canReuseMatch(savedSignature: signatures[game.id],
                    currentSignature: signature, hasMatch: matches[game.id] != nil)
                    ? matches[game.id].flatMap { cached in
                        let key = cached.epgChannelID ?? ""
                        let channel = preparedChannels[cached.id] ?? ProfessionalChannelMatcher.prepare(
                            channel: cached.name, listings: preparedListings[key] ?? [])
                        return Self.professionalScore(cached, game: game, preparedGame: preparedGame,
                                                      channel: channel, listings: programs[key] ?? [],
                                                      now: now)
                            .map { (cached, $0) }
                    }
                    : nil
                var evidence = reused?.evidence
                if reused == nil {
                    if let stream = Self.matchedStream(for: game, candidates: leagues[game.league] ?? [],
                                                       programs: programs, channels: preparedChannels,
                                                       preparedGame: preparedGame, now: now) {
                        matches[game.id] = stream
                        signatures[game.id] = signature
                        let key = stream.epgChannelID ?? ""
                        let chosen = preparedChannels[stream.id] ?? ProfessionalChannelMatcher.prepare(
                            channel: stream.name, listings: preparedListings[key] ?? [])
                        evidence = Self.professionalScore(stream, game: game, preparedGame: preparedGame,
                                                          channel: chosen, listings: programs[key] ?? [],
                                                          now: now)
                    } else {
                        matches.removeValue(forKey: game.id)
                        signatures.removeValue(forKey: game.id)
                    }
                }
                evidenceByGame[game.id] = evidence
                // Mirrors the college diagnostic above: a "no matching channel" report,
                // and the evidence tier behind a wrong one, should be readable from
                // device logs without static code review.
                let diagnostic = "game=\(game.id) network=\(game.broadcast) selectedID=\(matches[game.id]?.id.description ?? "none") evidence=\(evidence?.description ?? "none") candidates=\((leagues[game.league] ?? []).count) policy=\(reused == nil ? "professional-fresh" : "professional-reused")"
                Logger(subsystem: "com.nulldev85.NullSports", category: "ChannelMatch").info("\(diagnostic, privacy: .public)")
            }
            return (matches, signatures, matches != previousMatches, evidenceByGame,
                    collegeSlate.count, collegeCandidates.count, collegeSeconds, professionalSeconds)
            }.value
        }
        trace.note("  college", "\(result.4) games over \(result.5) candidates, "
                   + String(format: "%.1fs", result.6))
        trace.note("  professional", String(format: "%.1fs", result.7))
        guard DailyCachePolicy.shouldApplyRebuild(resultGeneration: generation, currentGeneration: matchGeneration,
            resultProfileID: profileID, currentProfileID: activeProfile?.id) else { return }
        if result.2 { gameStreamCache = result.0 }
        gameMatchSignatures = result.1
        matchEvidenceScores = result.3
        didCompleteMatching = true
        let newIdentities = identities.filter { result.0[$0.key] != nil }
        let identityChanged = newIdentities != matchedGameIdentities
        matchedGameIdentities = newIdentities
        await promoteCachedMatchesIfSafe()
        // Save changed matching results without rewriting the full guide on
        // every score/clock update. Writes remain serialized and atomic.
        if let profileID, force || result.2 || identityChanged || matchIdentities(now: now) != lastSavedMatchIdentities
            || lastSavedMatchDay.map({ !Calendar.current.isDate($0, inSameDayAs: now) }) != false {
            saveCache(profileID: profileID)
        }
    }

    // XMLTV is normally the slowest startup request. Reuse its same-day parsed
    // evidence while the replacement downloads, but only for a freshly returned
    // channel whose ID, name and EPG binding are all unchanged. The ordinary
    // matcher still rechecks the game, preserving every evidence threshold.
    /// Re-confirm the matches restored from cache against the channel list the
    /// server just returned.
    ///
    /// This used to run on the main actor, and it is not small work: a
    /// dictionary built from every one of twenty-six thousand channels, and
    /// then, for each game, a channel name and a day of its listings put
    /// through folding, lowercasing, splitting and rejoining. It runs whenever
    /// matching finishes and whenever a refresh lands, several times a launch.
    ///
    /// That is what froze the app. The picture kept playing -- video decodes
    /// on its own threads -- while nothing on screen would respond, and then
    /// the picture stopped too. The work happens in a detached task now and
    /// only the answer comes back to the main actor.
    private func promoteCachedMatchesIfSafe() async {
        guard channelsValidatedThisSession else {
            fastValidatedGameIDs = []
            return
        }
        let currentStreams = streams
        let games = gamesByLeague.values.flatMap { $0 }
        let restored = restoredMatchGameIDs
        let validatedLeagues = scheduleValidatedLeagues
        let identities = matchedGameIdentities
        let cache = gameStreamCache
        let listings = programsByChannel
        let now = Date()
        let generation = UUID()
        promoteGeneration = generation

        let found = await Task.detached(priority: .utility) {
            let freshByID = Dictionary(grouping: currentStreams, by: \.id).compactMapValues { $0.first }
            var matches: [String: XtreamStream] = [:]
            var evidenceByGame: [String: Int] = [:]
            for game in games {
                guard restored.contains(game.id),
                      validatedLeagues.contains(game.league),
                      identities[game.id] == Self.matchIdentity(game),
                      let cached = cache[game.id], let fresh = freshByID[cached.id],
                      DailyCachePolicy.isSameChannelSlot(cachedID: cached.id, freshID: fresh.id,
                        cachedName: cached.name, freshName: fresh.name,
                        cachedEPG: cached.epgChannelID, freshEPG: fresh.epgChannelID) else { continue }
                let freshListings = fresh.epgChannelID.flatMap { listings[$0] } ?? []
                let evidence: Int?
                if game.league == .ncaaf {
                    evidence = CollegeChannelMatcher.score(channel: fresh.name,
                        listings: Self.collegeListings(freshListings),
                        game: Self.collegeMatchup(game), now: now, allowNetworkFallback: false)
                } else {
                    evidence = Self.professionalScore(
                        fresh, game: game, preparedGame: Self.prepared(game),
                        channel: ProfessionalChannelMatcher.prepare(
                            channel: fresh.name,
                            listings: Self.matcherListings(["": freshListings])[""] ?? []),
                        listings: freshListings, now: now)
                }
                guard let evidence else { continue }
                matches[game.id] = fresh
                evidenceByGame[game.id] = evidence
            }
            return (matches, evidenceByGame)
        }.value

        // A newer pass, or a different provider, owns the answer now.
        guard promoteGeneration == generation else { return }
        var refreshedMatches = gameStreamCache
        var refreshedEvidence = matchEvidenceScores
        for (id, stream) in found.0 { refreshedMatches[id] = stream }
        for (id, evidence) in found.1 { refreshedEvidence[id] = evidence }
        let validated = Set(found.0.keys)
        if refreshedMatches != gameStreamCache { gameStreamCache = refreshedMatches }
        if refreshedEvidence != matchEvidenceScores { matchEvidenceScores = refreshedEvidence }
        if validated != fastValidatedGameIDs { fastValidatedGameIDs = validated }
    }

    func guidePrograms(for stream: XtreamStream) -> [CurrentProgram] {
        programs(for: stream)
    }

    /// `recentsOnly` is defaulted so the Apple TV call sites are unaffected.
    func guideStreams(categoryID: String?, favoritesOnly: Bool, query: String,
                      recentsOnly: Bool = false) -> [XtreamStream] {
        if let cached = guideListCache, cached.category == categoryID,
           cached.favorites == favoritesOnly, cached.recents == recentsOnly,
           cached.query == query { return cached.streams }
        let recentIDs = recentsOnly ? Set(recentStreamOrder) : []
        let filtered = streams.filter { stream in
            guard stream.streamType?.lowercased() != "radio_streams",
                  stream.streamType?.lowercased() != "radio" else { return false }
            if favoritesOnly && !isFavorite(stream) { return false }
            if recentsOnly && !recentIDs.contains(stream.id) { return false }
            if let categoryID, stream.categoryID != categoryID { return false }
            return query.isEmpty || stream.name.localizedCaseInsensitiveContains(query)
        }
        let result: [XtreamStream]
        if favoritesOnly {
            let streamsByID = Dictionary(grouping: filtered, by: \.id).compactMapValues { $0.first }
            result = favoriteStreamOrder.compactMap { streamsByID[$0] }
        } else if recentsOnly {
            // Most recently watched first — the order is the whole point.
            let streamsByID = Dictionary(grouping: filtered, by: \.id).compactMapValues { $0.first }
            result = recentStreamOrder.compactMap { streamsByID[$0] }
        } else {
            result = filtered.sorted {
                if ($0.num ?? Int.max) != ($1.num ?? Int.max) { return ($0.num ?? Int.max) < ($1.num ?? Int.max) }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        guideListCache = (categoryID, favoritesOnly, recentsOnly, query, result)
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

    /// Applies a drag reorder made against `listed`, the favorites currently on screen.
    /// Follows SwiftUI's `onMove` contract: `destination` indexes `listed` as it stood
    /// before the dragged rows lifted out of it.
    func moveFavorites(_ listed: [XtreamStream], fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = listed.map(\.id)
        let lifted = source.map { reordered[$0] }
        let insertion = destination - source.count(in: 0..<destination)
        for index in source.sorted(by: >) { reordered.remove(at: index) }
        reordered.insert(contentsOf: lifted, at: insertion)
        // Favorites the provider no longer carries are absent from `listed`, so they hold their slots.
        let listedIDs = Set(reordered)
        var next = reordered.makeIterator()
        favoriteStreamOrder = favoriteStreamOrder.map { listedIDs.contains($0) ? (next.next() ?? $0) : $0 }
        persistFavorites()
    }

    private func persistFavorites() {
        guideListCache = nil
        guard let profile = activeProfile else { return }
        profileDefaults.set(favoriteStreamOrder, forKey: favoritesKey + "." + profile.id.uuidString)
        if profileDefaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    // MARK: - Preferred channels by team

    /// The teams in a game, in the form the pure preference model works with.
    nonisolated private static func preferenceGame(_ game: SportsGame) -> TeamChannelGame {
        TeamChannelGame(league: game.league.rawValue,
                        homeTeam: game.homeTeam, homeAbbreviation: game.homeAbbreviation,
                        awayTeam: game.awayTeam, awayAbbreviation: game.awayAbbreviation)
    }

    /// What tapping this game should do. The decision itself lives in
    /// `TeamChannelPreferences.resolve`; this only supplies the provider's
    /// current reality — which channels exist, and whether matching has settled.
    func preferredChannel(for game: SportsGame) -> PreferredChannel {
        let teams = Self.preferenceGame(game)
        // Only the two saved channels are tested here; failover does its own,
        // wider search. Each is judged by `isStream(_:verifiedFor:)` — the same
        // evidence that authorizes an automatic match.
        var verified: Set<Int> = []
        for key in [teams.homeKey, teams.awayKey] {
            guard let saved = teamPreferences.preference(for: key),
                  let stream = stream(withID: saved.streamID),
                  isStream(stream, verifiedFor: game) else { continue }
            verified.insert(stream.id)
        }
        return teamPreferences.resolve(teams,
                                       // Unfinished *and* still working means wait.
                                       // Matching that has stopped without settling is
                                       // as good as it will get, so the picker opens
                                       // rather than a message that would never clear.
                                       matchingReady: matchIsReady(game) || !channelsAreSyncing,
                                       availableStreamIDs: Set(streams.map(\.id)),
                                       verifiedStreamIDs: verified,
                                       verifiedStreamID: verifiedStream(for: game)?.id)
    }

    func stream(withID id: Int) -> XtreamStream? {
        streams.first { $0.id == id }
    }

    /// Which sides of this game a preference can be saved for, home first.
    func preferenceSides(for game: SportsGame) -> [TeamChannelSide] {
        let teams = Self.preferenceGame(game)
        return [TeamChannelSide(key: teams.homeKey, team: game.homeTeam, isHome: true),
                TeamChannelSide(key: teams.awayKey, team: game.awayTeam, isHome: false)]
            .filter { $0.key.isUsable }
    }

    func savePreference(_ stream: XtreamStream, for key: TeamChannelKey, teamName: String) {
        teamPreferences.set(TeamChannelPreference(streamID: stream.id, channelName: stream.name,
                                                  teamName: teamName), for: key)
        persistTeamPreferences()
    }

    func removePreference(for key: TeamChannelKey) {
        teamPreferences.remove(for: key)
        persistTeamPreferences()
    }

    func removeAllPreferences() {
        teamPreferences.removeAll()
        persistTeamPreferences()
    }

    /// True when the provider no longer carries a saved preference's channel.
    /// Settings says so rather than hiding the row: the channel may come back,
    /// and deleting the preference is the viewer's call.
    func preferenceChannelIsAvailable(_ preference: TeamChannelPreference) -> Bool {
        streams.contains { $0.id == preference.streamID }
    }

    // MARK: - Recently watched

    /// Recorded only once a stream is genuinely playing — see the call site in
    /// the player surfaces. Opening a channel that never decodes must not push
    /// a dead feed to the top of the list.
    func recordRecentChannel(_ stream: XtreamStream) {
        let updated = RecentChannels.updated(recentStreamOrder, watching: stream.id)
        guard updated != recentStreamOrder else { return }
        recentStreamOrder = updated
        guideListCache = nil
        persistRecentChannels()
    }

    /// Most recent first, with anything the provider no longer carries dropped.
    /// Filtering on read rather than on write means a channel that vanishes from
    /// one refresh and returns in the next keeps its place, while never being
    /// playable from a stale entry in between.
    var recentStreams: [XtreamStream] {
        let byID = Dictionary(grouping: streams, by: \.id).compactMapValues(\.first)
        return RecentChannels.resolved(recentStreamOrder, available: Set(byID.keys))
            .compactMap { byID[$0] }
    }

    func clearRecentChannels() {
        guard !recentStreamOrder.isEmpty else { return }
        recentStreamOrder = []
        guideListCache = nil
        persistRecentChannels()
    }

    private func persistRecentChannels() {
        guard let profile = activeProfile else { return }
        profileDefaults.set(recentStreamOrder, forKey: recentsKey + "." + profile.id.uuidString)
    }

    private func restoreRecentChannels() {
        guard let profile = activeProfile,
              let saved = profileDefaults.array(forKey: recentsKey + "." + profile.id.uuidString) as? [Int] else {
            recentStreamOrder = []
            return
        }
        recentStreamOrder = saved
    }

    // MARK: - Failover

    /// Channels Lineup may move to when the current feed stops working.
    ///
    /// Every entry is either the viewer's own saved channel or one the same
    /// matcher that authorizes normal playback verified for *this* game, so
    /// failover can never wander onto an unrelated feed. Bounded to the league's
    /// own channel index and to a handful of alternates, since this runs at the
    /// moment a stream is already failing.
    func failoverPlan(for game: SportsGame, limit: Int = 4) -> [FailoverChannel] {
        let verified = verifiedStream(for: game)
        let preferred = preferredFailoverChannel(for: game)
        let listings = programsByChannel
        let now = Date()
        let alternates = streams(for: game.league)
            .filter { $0.id != verified?.id && $0.id != preferred?.streamID }
            .filter { Self.carriesGame($0, game: game,
                                       listings: $0.epgChannelID.flatMap { listings[$0] } ?? [],
                                       now: now) }
            .prefix(limit)
            .map { FailoverChannel(streamID: $0.id, name: $0.name, reason: .alternate) }
        return FailoverPlanner.plan(
            preference: preferred,
            verified: verified.map { FailoverChannel(streamID: $0.id, name: $0.name, reason: .verified) },
            alternates: Array(alternates))
    }

    /// The viewer's saved channel, and only when it is verified for this game.
    /// Failing over to the regional network during a nationally exclusive game
    /// would be switching to a feed that is not showing it.
    private func preferredFailoverChannel(for game: SportsGame) -> FailoverChannel? {
        verifiedPreferredStream(for: game)
            .map { FailoverChannel(streamID: $0.id, name: $0.name, reason: .preference) }
    }

    private func persistTeamPreferences() {
        // Strictly per provider, and never merged across them the way favorites
        // are: a channel identifier only means something inside the provider
        // that issued it.
        guard let profile = activeProfile,
              let data = try? JSONEncoder().encode(teamPreferences) else { return }
        profileDefaults.set(data, forKey: teamPreferencesKey + "." + profile.id.uuidString)
    }

    private func restoreTeamPreferences() {
        guard let profile = activeProfile,
              let data = profileDefaults.data(forKey: teamPreferencesKey + "." + profile.id.uuidString),
              let saved = try? JSONDecoder().decode(TeamChannelPreferences.self, from: data) else {
            teamPreferences = TeamChannelPreferences()
            return
        }
        teamPreferences = saved
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

    private func restoreFavorites() {
        guard let profile = activeProfile else {
            favoriteStreamOrder = []
            return
        }
        let currentKey = favoritesKey + "." + profile.id.uuidString
        if let saved = profileDefaults.array(forKey: currentKey) as? [Int], !saved.isEmpty {
            favoriteStreamOrder = saved
            return
        }

        // Re-entering a provider creates a new UUID. If only the provider record
        // disappeared, its per-profile favorites remain under the old UUID and
        // look empty from the new one. When this profile has no favorites yet,
        // merge every surviving orphan list in stable order; stale stream IDs
        // simply do not resolve against the current provider. Keep the old keys
        // as backups rather than deleting the only surviving copies.
        let knownKeys = Set(profiles.map { favoritesKey + "." + $0.id.uuidString })
        let orphaned = profileDefaults.dictionaryRepresentation().sorted { $0.key < $1.key }.compactMap { key, value -> [Int]? in
            guard key.hasPrefix(favoritesKey + "."), !knownKeys.contains(key) else { return nil }
            if let ids = value as? [Int], !ids.isEmpty { return ids }
            guard let values = value as? [Any] else { return nil }
            let ids = values.compactMap { ($0 as? NSNumber)?.intValue }
            return ids.isEmpty ? nil : ids
        }
        var seen = Set<Int>()
        let recovered = orphaned.flatMap { $0 }.filter { seen.insert($0).inserted }
        guard !recovered.isEmpty else {
            favoriteStreamOrder = []
            return
        }
        favoriteStreamOrder = recovered
        profileDefaults.set(recovered, forKey: currentKey)
        if profileDefaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    // Let existing operations retire before replacing provider state. Their
    // cleanup must never reset loading flags belonging to the next provider.
    private func waitForProviderWork() async -> Bool {
        while bootstrapInFlight || libraryRefreshInFlight || isGuideLoading
            || scheduleRefreshInFlight || channelMatchingWorkCount > 0 {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        return !Task.isCancelled
    }

    func selectProfile(_ profile: XtreamProfile) async {
        guard !isSwitchingProfile, profiles.contains(where: { $0.id == profile.id }),
              activeProfile?.id != profile.id else { return }
        isSwitchingProfile = true
        guard await waitForProviderWork() else { isSwitchingProfile = false; return }
        persistFavorites()
        resetProviderState()
        activeProfile = profile
        restoreFavorites()
        restoreTeamPreferences()
        restoreRecentChannels()
        persistProfiles()
        isSwitchingProfile = false
        await bootstrap()
    }

    func removeActiveProfile() {
        guard let profile = activeProfile else { return }
        Task { await removeProfile(profile) }
    }

    func removeProfile(_ profile: XtreamProfile) async {
        guard !isSwitchingProfile, profiles.contains(where: { $0.id == profile.id }) else { return }
        isSwitchingProfile = true
        guard await waitForProviderWork() else { isSwitchingProfile = false; return }
        let removingActive = activeProfile?.id == profile.id
        KeychainStore.delete(profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        profileDefaults.removeObject(forKey: favoritesKey + "." + profile.id.uuidString)
        profileDefaults.removeObject(forKey: teamPreferencesKey + "." + profile.id.uuidString)
        profileDefaults.removeObject(forKey: recentsKey + "." + profile.id.uuidString)
        if removingActive {
            resetProviderState()
            activeProfile = profiles.first
            restoreFavorites()
            restoreTeamPreferences()
            restoreRecentChannels()
        }
        // Finish an already queued cache write before deleting this cache.
        await cacheWriteTask?.value
        Self.removeCaches(profileID: profile.id)
        persistProfiles()
        isSwitchingProfile = false
        if removingActive, activeProfile != nil { await bootstrap() }
    }

    private func resetProviderState() {
        // A refresh started for the previous provider must never land in the
        // next one's state. Everything provider-scoped — cached matches,
        // favorites, recent channels, preferences — is re-read from that
        // provider's own keys afterwards.
        backgroundRefresh?.cancel()
        backgroundRefresh = nil
        isRefreshingInBackground = false
        errorMessage = nil
        indexGeneration = UUID()
        matchGeneration = UUID()
        guideListCache = nil
        categories = []
        streams = []
        professionalStreams = []
        leagueStreamCache = [:]
        sportsIndexReady = false
        gameStreamCache = [:]
        matchEvidenceScores = [:]
        didCompleteMatching = false
        fastValidatedGameIDs = []
        restoredMatchGameIDs = []
        lastUnmatchedProviderRefresh = nil
        channelsValidatedThisSession = false
        guideValidatedThisSession = false
        scheduleValidatedLeagues = []
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
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            profileDefaults.set(data, forKey: profilesKey)
        }
        profileDefaults.set(activeProfile?.id.uuidString, forKey: activeKey)
        if profileDefaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    func restoreCloudSettings() async {
        guard let data = profileDefaults.data(forKey: profilesKey),
              let saved = try? JSONDecoder().decode([XtreamProfile].self, from: data) else { return }
        let activeID = profileDefaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        profiles = saved
        let selected = saved.first { $0.id == activeID } ?? saved.first
        if selected?.id != activeProfile?.id {
            resetProviderState()
            activeProfile = selected
            restoreFavorites()
            if selected != nil { await bootstrap() }
        } else {
            activeProfile = selected
            restoreFavorites()
        }
    }
}
