import Foundation
import OSLog
import Observation

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
    /// Which fields a channel list was read with. A list read before
    /// channels carried catch-up was read without it, and the digest saying
    /// "nothing changed" would keep it that way until the provider happened
    /// to change its list; a different number throws the digest away.
    var channelFormat: Int? = nil
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
    #if os(iOS)
    var listingFacts: [String: SportsIndexFacts.Fact]? = nil
    #endif
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
@Observable
final class SportsLibrary {
    /// The fields a cached channel list was read with: 2 since channels
    /// carried catch-up. See `LibraryState.channelFormat`.
    nonisolated static let channelFormat = 2
    private(set) var isSwitchingProfile = false
    private let profileDefaults: UserDefaults
    private let credentials: ProviderCredentialStore
    private let persistsActiveSelection: Bool
    private(set) var disabledProviderIDs: Set<UUID> = []
    #if os(iOS)
    @ObservationIgnored private var providerContexts: [UUID: SportsLibrary] = [:]
    @ObservationIgnored private var providerContextLoads: [UUID: Task<SportsLibrary?, Never>] = [:]
    @ObservationIgnored private var providerBootstraps: [UUID: Task<Void, Never>] = [:]
    private var providerContextsRevision = 0
    @ObservationIgnored private var combinedGuideContext: SportsLibrary?
    @ObservationIgnored private var combinedRegistry: MobileProviderStreamRegistry?
    @ObservationIgnored private weak var combinedRoot: SportsLibrary?
    @ObservationIgnored private weak var providerOwner: SportsLibrary?
    @ObservationIgnored private var mirroredStreamsRevision = -1
    @ObservationIgnored private var mirroredGuideRevision = -1
    @ObservationIgnored private var mirroredPreparedRevision = -1
    @ObservationIgnored private var combinedSources: [Int: MobileProviderPlaybackSource] = [:]
    @ObservationIgnored private var combinedDisplayIDs: [MobileProviderChannel.ID: Int] = [:]
    @ObservationIgnored private var combinedProviderContexts: [UUID: SportsLibrary] = [:]
    @ObservationIgnored private var combinedSignature: [String] = []
    @ObservationIgnored private var combinedLoadCount = 0
    private(set) var providerProblems: [UUID: String] = [:]
    #endif
    private(set) var profiles: [XtreamProfile] = []
    var activeProfile: XtreamProfile?
    private(set) var categories: [XtreamCategory] = []
    private(set) var streams: [XtreamStream] = [] {
        didSet { streamIndexCache = nil; streamsRevision &+= 1 }
    }
    /// Moves with every new channel list, for what is worked out from one.
    private(set) var streamsRevision = 0
    private(set) var professionalStreams: [XtreamStream] = []
    private(set) var programsByChannel: [String: [CurrentProgram]] = [:] {
        didSet { guideRevision &+= 1 }
    }
    /// Moves with every new guide.
    private(set) var guideRevision = 0
    private(set) var favoriteStreamOrder: [Int] = []
    private(set) var teamPreferences = TeamChannelPreferences()
    private(set) var gameChannelSelections = GameChannelSelections()
    private(set) var recentStreamOrder: [Int] = []
    private(set) var gamesByLeague: [SportsLeague: [SportsGame]] = [:] {
        didSet { gamesRevision &+= 1 }
    }
    /// Moves with every new schedule, for what looks at each one as it
    /// comes: game alerts and reminders.
    private(set) var gamesRevision = 0
    private(set) var scheduleLoadedLeagues: Set<SportsLeague> = []
    private(set) var scheduleErrorMessage: String?
    private(set) var isScheduleLoading = false
    private(set) var isLoading = false
    private(set) var isGuideLoading = false
    var errorMessage: String?
    /// How far a refresh of the channel list, the guide and the matches has
    /// got, for the "Refreshing Data" pop-up. Watched by the pop-up alone.
    let refreshProgress = DataRefreshProgress()

    // Named for the app's old name on purpose: this is where existing installs
    // already keep their data, and renaming the key would hide it from them.
    private let profilesKey = SportsLibrary.storedProfilesKey
    private let activeKey = SportsLibrary.storedActiveKey
    nonisolated private static let storedProfilesKey = "NullSports.profiles"
    nonisolated private static let storedActiveKey = "NullSports.activeProfile"

    /// The provider in use, as saved -- for the Library, which plays the same
    /// provider's films and shows without holding this store.
    nonisolated static func storedActiveProfile(in defaults: UserDefaults) -> XtreamProfile? {
        guard let data = defaults.data(forKey: storedProfilesKey),
              let saved = try? JSONDecoder().decode([XtreamProfile].self, from: data) else { return nil }
        let activeID = defaults.string(forKey: storedActiveKey).flatMap(UUID.init(uuidString:))
        return saved.first { $0.id == activeID } ?? saved.first
    }
    private let favoritesKey = "NullSports.favoriteStreams"
    private let teamPreferencesKey = "NullSports.teamChannelPreferences"
    private let gameChannelSelectionsKey = "NullSports.gameChannelSelections"
    private let followedTeamsKey = "NullSports.followedTeams"
    private let recentsKey = "NullSports.recentChannels"
    private let scheduleKey = "NullSports.lastGoodSchedule"
    private var leagueStreamCache: [SportsLeague: [XtreamStream]] = [:]
    private var sportsIndexReady = false
    private var channelsValidatedThisSession = false
    private var guideValidatedThisSession = false
    private var scheduleValidatedLeagues: Set<SportsLeague> = []
    private var gameStreamCache: [String: XtreamStream] = [:]
    @ObservationIgnored private var measuredPlaybackURLs: [String: (url: URL, expires: Date)] = [:]
    @ObservationIgnored private var eventChannelCache: [String: (channels: [LiveEventChannel], expires: Date)] = [:]
    private var matchEvidenceScores: [String: Int] = [:]
    private var didCompleteMatching = false
    // Same-day matches can be released before the large XMLTV download finishes,
    // after the fresh schedule and channel list confirm their inputs.
    private var fastValidatedGameIDs: Set<String> = []
    @ObservationIgnored private var restoredMatchGameIDs: Set<String> = []
    @ObservationIgnored private var lastUnmatchedProviderRefresh: Date?
    @ObservationIgnored private var gameMatchSignatures: [String: String] = [:]
    private var matchedGameIdentities: [String: [String]] = [:]
    private var preparedMatches: [String: PreparedLiveMatch] = [:] {
        didSet { preparedMatchesRevision &+= 1 }
    }
    private var preparedMatchesRevision = 0
    @ObservationIgnored private var eventsNeedingPreparation: Set<String> = []
    @ObservationIgnored private var dailyPreparedAt: Date?
    @ObservationIgnored private var preparedWriteTask: Task<Void, Never>?
    @ObservationIgnored private var didRestoreProviderCache = false
    @ObservationIgnored private var hasFullCatalog = false
    @ObservationIgnored private var hasFullGuide = false
    @ObservationIgnored private var preparedPlaylistURLs: [Int: URL] = [:]
    @ObservationIgnored private var lastBackgroundRefreshAttempt: Date?
    @ObservationIgnored private var providerGeneration = UUID()
    private let preparedCacheDirectory: URL?
    private let automaticRefreshes: Bool
    private let providerSession: URLSession
    private let scheduleCacheLocation: URL?
    @ObservationIgnored private var scheduleSnapshotAt: Date?
    @ObservationIgnored private var cachedRestoreInFlight = false
    @ObservationIgnored private var cachedRestoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var indexGeneration = UUID()
    @ObservationIgnored private var matchGeneration = UUID()
    #if os(iOS)
    private let mobileSportsWork = MobileSportsWork()
    private let mobileIndexFacts = SportsIndexFacts()
    private var mobileEventCandidates: (generation: UUID, identities: [String: [String]],
        games: [String: Set<Int>], collegePool: Set<Int>)?
    #endif
    @ObservationIgnored private var guideListCache: (category: String?, favorites: Bool, recents: Bool, query: String, streams: [XtreamStream])?
    @ObservationIgnored private var didRestoreSchedule = false
    @ObservationIgnored private var scheduleDay: Date?
    private var bootstrapInFlight = false
    private var libraryRefreshInFlight = false
    private var channelMatchingWorkCount = 0 {
        didSet {
            #if !os(iOS)
            // Matching a refresh sets off is part of it. Matching on its own
            // -- after a score changed -- starts no refresh of its own.
            if oldValue == 0, channelMatchingWorkCount > 0 { refreshProgress.start(.matching) }
            if oldValue > 0, channelMatchingWorkCount == 0 { refreshProgress.finish(.matching) }
            #endif
        }
    }
    @ObservationIgnored private var cacheWriteTask: Task<Void, Never>?
    @ObservationIgnored private var guideRefresh: Task<Void, Never>?
    /// Discards the answer from a promote pass that a newer one has overtaken.
    @ObservationIgnored private var promoteGeneration = UUID()
    /// Digests of what the server last sent for each list, carried across
    /// launches in the state file. A refresh that gets the same bytes back
    /// stops at the digest: nothing is decoded, compared, or written.
    @ObservationIgnored private var categoriesDigest: String?
    @ObservationIgnored private var streamsDigest: String?
    @ObservationIgnored private var guideDigest: String?
    /// What is already on disk, so a write can be skipped when it would put
    /// back exactly what is there. Set when a file is read and when one is
    /// written; nil means "unknown", which writes.
    @ObservationIgnored private var savedChannelsDigest: String?
    @ObservationIgnored private var savedGuideDigest: String?
    /// Set when a one-file cache was read, cleared once the three files that
    /// replace it have been written.
    @ObservationIgnored private var legacyCacheNeedsRetiring = false
    /// Held while a provider refresh is running *behind* restored cache, so a
    /// second one cannot start on top of it. The screen stays usable
    /// throughout, which is why nothing here feeds `channelsAreSyncing`.
    @ObservationIgnored private var backgroundRefresh: Task<Void, Never>?
    @ObservationIgnored private var scheduleWriteTask: Task<Void, Never>?
    /// When matching last ran, for the rematch a score-only refresh waits on.
    @ObservationIgnored private var lastMatchingPass = Date.distantPast
    private var scheduleRefreshInFlight = false
    @ObservationIgnored private var lastSavedMatchIdentities: [String: [String]] = [:]
    @ObservationIgnored private var lastSavedMatchDay: Date?
    private var guideUpdatedAt: Date?
    private var libraryUpdatedAt: Date?
    @ObservationIgnored private var tomorrowScheduleUpdatedAt: Date?
    private let guideLifetime: TimeInterval = 3 * 60 * 60
    private let libraryLifetime: TimeInterval = 6 * 60 * 60
    private let tomorrowScheduleLifetime: TimeInterval = 3 * 60 * 60

    init(profileDefaults: UserDefaults = .standard, credentials: ProviderCredentialStore = .keychain,
         providerID: UUID? = nil, persistsActiveSelection: Bool = true,
         preparedCacheDirectory: URL? = nil, automaticRefreshes: Bool = true,
         providerSession: URLSession = .shared, scheduleCacheLocation: URL? = nil) {
        self.profileDefaults = profileDefaults
        self.credentials = credentials
        self.persistsActiveSelection = persistsActiveSelection
        self.preparedCacheDirectory = preparedCacheDirectory
        self.automaticRefreshes = automaticRefreshes
        self.providerSession = providerSession
        self.scheduleCacheLocation = scheduleCacheLocation
        disabledProviderIDs = Set((profileDefaults.stringArray(forKey: "Lineup.disabledIPTVProviders.v1") ?? []).compactMap(UUID.init(uuidString:)))
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
        if let providerID { activeProfile = profiles.first { $0.id == providerID } }
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
        restoreGameChannelSelections()
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

    private func preparedMatch(for game: SportsGame, now: Date = Date()) -> PreparedLiveMatch? {
        guard game.isLive || game.isUpcoming, let saved = preparedMatches[game.id],
              saved.covers(game, now: now) else { return nil }
        return saved
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
                    // A day of tennis starts a match somewhere every few
                    // minutes, and most never get a channel of their own:
                    // counted, they would download the provider again every
                    // two minutes from first ball to last. A followed
                    // player's match is worth it; the rest are not.
                    && (!game.league.isTennis || isFollowing(game))
                    && ProviderRefreshPolicy.needsRefresh(gameStart: game.start,
                        providerFetchedAt: fetchedAt, now: now)
            }
        }
    }

    // A channel's guide usually only names the game once it is under way, and a
    // scoreless opening gives the schedule nothing to change, so nothing asks
    // matching to look again. Retry rather than leave a live game unmatched:
    // on every refresh around its start, when providers add a game's channel
    // and name it in the guide, and every few minutes after. A slate always
    // has some live game no provider carries, and retrying it every thirty
    // seconds all day rematched every channel just as often.
    private var hasUnmatchedLiveGame: Bool {
        let now = Date()
        let rested = now.timeIntervalSince(lastMatchingPass) >= Self.scoreOnlyRematchInterval
        return gamesByLeague.values.contains { games in
            games.contains { game in
                game.isLive && gameStreamCache[game.id] == nil
                    && (rested || now < game.start.addingTimeInterval(ProviderRefreshPolicy.window))
            }
        }
    }

    // Startup refreshes gate automatic matching; the Guide remains browsable.
    // Later score polling does not block already validated selections.
    var channelsAreSyncing: Bool {
        #if os(iOS)
        if let combinedRoot {
            return isLoading || combinedRoot.channelsAreSyncing
                || combinedProviderContexts.values.contains { $0.channelsAreSyncing }
        }
        #endif
        return bootstrapInFlight || libraryRefreshInFlight || isGuideLoading || channelMatchingWorkCount > 0
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

    private func rebuildProfessionalStreams(changedStreamIDs: Set<Int> = []) async {
        sportsIndexReady = false
        channelMatchingWorkCount += 1
        defer { channelMatchingWorkCount -= 1 }
        let generation = UUID()
        indexGeneration = generation
        // The old index's matcher must not publish while its replacement builds.
        matchGeneration = UUID()
        #if os(iOS)
        let progress = refreshProgress
        let indexWork = progress.start(.indexing)
        defer { progress.finish(indexWork) }
        #endif
        let profileID = activeProfile?.id
        let currentCategories = categories
        let currentStreams = streams
        let currentPrograms = programsByChannel
        #if os(iOS)
        let facts: SportsIndexFacts? = mobileIndexFacts
        #else
        let facts: SportsIndexFacts? = nil
        #endif
        // Timed apart from the matching that follows it. One number for the
        // pair could not say which half was slow, and for two rounds it was
        // read as though it were all the matching's.
        let worker = Task.detached(priority: .utility) {
            try Self.makeSportsIndex(categories: currentCategories, streams: currentStreams,
                                     programs: currentPrograms, facts: facts)
        }
        #if os(iOS)
        let workID = mobileSportsWork.replace(.index, cancel: { worker.cancel() })
        defer { mobileSportsWork.finish(.index, id: workID) }
        #endif
        guard let built = try? await StartupTrace.shared.measure("build sports index", {
            try await worker.value
        }) else {
            StartupTrace.shared.note("sports index superseded", "obsolete work stopped")
            return
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
        if !changedStreamIDs.isEmpty {
            let affected = Set(index.leagues.compactMap { league, channels in
                channels.contains { changedStreamIDs.contains($0.id) } ? league : nil
            })
            for game in gamesByLeague.values.joined()
                where affected.contains(game.league) || game.league == .ncaaf {
                eventsNeedingPreparation.insert(game.id)
            }
        }
        let byLeague = SportsLeague.allCases
            .map { "\($0.rawValue) \(index.leagues[$0]?.count ?? 0)" }.joined(separator: ", ")
        StartupTrace.shared.note("index built",
                                 "\(index.professional.count) sports channels of \(currentStreams.count) — " + byLeague)
        #if os(iOS)
        progress.finish(indexWork)
        #endif
        await rebuildGameStreamCache(force: true)
    }

    /// The index, and how long each part of building it took.
    ///
    /// The timings come back rather than being recorded in place because this
    /// runs off the main actor, and because one number for the whole thing was
    /// read wrongly twice.
    nonisolated private static func makeSportsIndex(
        categories: [XtreamCategory], streams: [XtreamStream], programs: [String: [CurrentProgram]],
        facts: SportsIndexFacts? = nil
    ) throws -> (index: SportsIndex, phases: [(name: String, seconds: Double)]) {
        var phases: [(name: String, seconds: Double)] = []
        func time<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try work()
            phases.append((name, ProcessInfo.processInfo.systemUptime - start))
            return value
        }

        let categoryNames = categories.reduce(into: [String: String]()) { $0[$1.id] = $1.matchingName }
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
            func compute() -> Set<SportsLeague> {
                let text = SportsMatchText(
                    alreadyLowercased: listings.map { "\($0.title) \($0.detail)" }
                        .joined(separator: " ").lowercased(), scannable: false)
                return Set(SportsLeague.allCases.filter { $0.matches(text) })
            }
            let found = facts?.leagues(channelID: epgID, listings: listings, compute: compute) ?? compute()
            listingLeagues[epgID] = found
            return found
        }

        let professional = try time("channel filter") {
            try streams.filter { stream in
                try Task.checkCancellation()
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
            return try await saveConnectedProfile(profile, secret: password)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addPlaylist(name: String, playlist: String, guide: String) async -> Bool {
        do {
            let credentials = try PlaylistCredentials(playlist: playlist, guide: guide)
            // Public profile metadata holds only the origin, never a credential
            // path, query string, Drive file ID, or EPGenius token.
            var origin = URLComponents()
            origin.scheme = credentials.playlist.scheme
            origin.host = credentials.playlist.host
            origin.port = credentials.playlist.port
            var profile = XtreamProfile(name: name.isEmpty ? "My Playlist" : name,
                serverURL: origin.string ?? "", username: "M3U playlist")
            profile.connectionKind = "m3u"
            _ = try await PlaylistDownloads.shared.load(profileID: profile.id, secret: credentials.encoded)
            return try await saveConnectedProfile(profile, secret: credentials.encoded)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func saveConnectedProfile(_ profile: XtreamProfile, secret: String) async throws -> Bool {
            try credentials.save(secret, profile.id)
            passwordCache = nil
            profiles.append(profile)
            // Additional providers are saved without interrupting the current one.
            let isFirstProfile = activeProfile == nil
            if isFirstProfile {
                activeProfile = profile
                restoreFavorites()
                restoreTeamPreferences()
                restoreGameChannelSelections()
                restoreRecentChannels()
            }
            persistProfiles()
            if isFirstProfile { await reload() }
            return true
    }

    func bootstrap() async {
        guard let profile = activeProfile, !bootstrapInFlight else { return }
        let requestGeneration = providerGeneration
        bootstrapInFlight = true
        if !didRestoreProviderCache { cachedRestoreInFlight = true }
        defer {
            if providerGeneration == requestGeneration {
                finishCachedRestore()
                bootstrapInFlight = false
            }
        }
        let trace = StartupTrace.shared
        // Prepared playback is independent of the full catalog and guide.
        if !didRestoreProviderCache {
            trace.begin()
            _ = await trace.measure("read prepared playback", { await restorePreparedMatches() })
        }
        guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
        if !didRestoreSchedule {
            let key = scheduleKey
            let location = scheduleCacheLocation ?? Self.scheduleURL()
            let legacy = profileDefaults.data(forKey: key)
            let cached = await Task.detached(priority: .utility) { () -> ScheduleCache? in
                // Earlier versions kept it in preferences; it is read from
                // there once and taken out.
                let saved = (try? Data(contentsOf: location)) ?? legacy
                guard let data = saved else { return nil }
                // Undated legacy snapshots need a fresh fetch, not a guessed date.
                return try? JSONDecoder().decode(ScheduleCache.self, from: data)
            }.value
            guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
            didRestoreSchedule = true
            profileDefaults.removeObject(forKey: key)
            let now = Date()
            if let cached, DailyCachePolicy.canCarryMatches(savedAt: cached.savedAt, now: now), gamesByLeague.isEmpty {
                let today = Calendar.current.startOfDay(for: now)
                gamesByLeague = Dictionary(uniqueKeysWithValues: SportsLeague.allCases.map { league in
                    (league, (cached.games[league.rawValue] ?? []).filter { game in
                        game.start >= today || (game.isLive && now.timeIntervalSince(game.start) < 12 * 60 * 60)
                    })
                })
                scheduleLoadedLeagues = Set(cached.games.keys.compactMap(SportsLeague.init(rawValue:)))
                scheduleDay = today
                scheduleSnapshotAt = cached.savedAt
            }
        }
        if !didRestoreProviderCache {
            trace.note("restore provider", preparedMatches.isEmpty ? "no prepared games" : "prepared playback already available")
        }
        let head: RestoredLibrary?
        if !didRestoreProviderCache {
            head = await trace.measure("read cache: channels + state", { await Self.readHead(profileID: profile.id) })
            guard providerGeneration == requestGeneration else { return }
            didRestoreProviderCache = true
        } else { head = nil }
        if let restored = head {
            guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
            // The channel list goes up first. Every screen in the app needs it
            // and nothing needs it sooner, and it is a fraction of the size of
            // the guide that used to be decoded in front of it.
            categories = restored.channels.categories
            streams = restored.channels.streams
            var patchedCatalog = false
            // The compact snapshot is independently durable. If the large
            // cache is older (or a previous run ended between its writes), it
            // must not withdraw a channel that was just made playable.
            if !preparedMatches.isEmpty {
                var byID = Dictionary(streams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var groups = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for match in preparedMatches.values {
                    for stream in match.streams {
                        if byID[stream.id] != stream { patchedCatalog = true }
                        byID[stream.id] = stream
                    }
                    for (id, name) in match.categoryNames {
                        if groups[id]?.matchingName != name { patchedCatalog = true }
                        groups[id] = .init(categoryID: id, categoryName: name)
                    }
                }
                let existing = Set(streams.map(\.id))
                streams = streams.map { byID[$0.id] ?? $0 } + byID.values.filter { !existing.contains($0.id) }
                categories = groups.values.sorted { $0.id < $1.id }
            }
            hasFullCatalog = true
            guideListCache = nil
            let state = restored.state
            guideUpdatedAt = state?.guideUpdatedAt
            libraryUpdatedAt = state?.libraryUpdatedAt
            categoriesDigest = state?.categoriesDigest
            // A list read with older fields is read again, in full.
            streamsDigest = state?.channelFormat == Self.channelFormat ? state?.streamsDigest : nil
            guideDigest = state?.guideDigest
            if patchedCatalog {
                categoriesDigest = nil
                streamsDigest = nil
                libraryUpdatedAt = nil
            }
            // Now the expensive half, with something already on screen. The
            // index and the matching below both read it, so it has to be in
            // place before either of them runs -- but not before the channels
            // are, which is the whole change.
            trace.note("channels on screen", "\(streams.count) channels, \(categories.count) categories")
            if let carried = restored.guide {
                legacyCacheNeedsRetiring = true
                programsByChannel = carried
                hasFullGuide = true
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
                guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else {
                    return
                }
                if let guide { programsByChannel = guide; hasFullGuide = true }
                isGuideLoading = false
                trace.note("guide on screen", "\(programsByChannel.count) channels with listings")
            }
            var restoredPrograms = programsByChannel
            var patchedGuide = false
            for match in preparedMatches.values {
                for (id, entries) in match.programs {
                    if restoredPrograms[id] != entries { patchedGuide = true }
                    restoredPrograms[id] = entries
                }
            }
            if patchedGuide { guideDigest = nil; guideUpdatedAt = nil }
            if patchedGuide { programsByChannel = restoredPrograms }
            guideListCache = nil
            savedChannelsDigest = channelsSignature
            savedGuideDigest = guideSignature
            let now = Date()
            if preparedMatches.isEmpty, state?.matchCacheVersion == 2, let saved = state?.dailyMatches {
                let identities = matchIdentities(now: now)
                let legacyIdentities = Dictionary(gamesByLeague.values.joined().filter { identities[$0.id] != nil }
                    .map { ($0.id, PreparedLiveMatch.legacyIdentity(for: $0)) }, uniquingKeysWith: { first, _ in first })
                gameStreamCache = saved.restore(identities: identities, available: streams, now: now)
                    .merging(saved.restore(identities: legacyIdentities, available: streams, now: now),
                             uniquingKeysWith: { current, _ in current })
                restoredMatchGameIDs = Set(gameStreamCache.keys)
                matchedGameIdentities = identities.filter { gameStreamCache[$0.key] != nil }
                lastSavedMatchIdentities = saved.identities
                lastSavedMatchDay = saved.savedAt
                // Restored matches are kept as a pass keeps its own: in the
                // form a pass writes, or the first pass after a launch would
                // look for every one of them again.
                for game in gamesByLeague.values.flatMap({ $0 }) where gameStreamCache[game.id] != nil {
                    gameMatchSignatures[game.id] = Self.matchSignature(game)
                }
                await prepareRestoredPrimaryMatches(savedAt: saved.savedAt)
                guard providerGeneration == requestGeneration else { return }
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
                #if os(iOS)
                mobileIndexFacts.restore(index.listingFacts ?? [:])
                #endif
                trace.note("sports index restored", "from cache")
                // An incomplete slate is matched behind the screen below.
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
                trace.note("sports index needs background rebuild", why)
            }
        }
        guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
        finishCachedRestore()
        if automaticRefreshes { refreshSchedule(showsLoading: false) }
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

    private func finishCachedRestore() {
        cachedRestoreInFlight = false
        let waiting = cachedRestoreWaiters
        cachedRestoreWaiters = []
        for continuation in waiting { continuation.resume() }
    }

    private func waitForCachedRestore() async {
        guard cachedRestoreInFlight else { return }
        await withCheckedContinuation { cachedRestoreWaiters.append($0) }
    }

    /// Secondary providers use this same local restore before any catalog I/O.
    @discardableResult
    func restorePreparedMatches(now: Date = Date()) async -> Bool {
        guard preparedMatches.isEmpty, let profile = activeProfile,
              !disabledProviderIDs.contains(profile.id), let secret = credentials.password(profile.id) else { return false }
        let directory = preparedCacheDirectory
        let requestGeneration = providerGeneration
        let restored = await Task.detached(priority: .userInitiated) {
            let saved = PreparedLiveStore.read(profile: profile, directory: directory)
            return (saved, PreparedPlaylistSources.open(saved?.playlistSources, secret: secret))
        }.value
        guard !Task.isCancelled, providerGeneration == requestGeneration, activeProfile == profile, credentials.password(profile.id) == secret,
              let saved = restored.0, !profile.isPlaylist || !restored.1.isEmpty else { return false }
        preparedPlaylistURLs = restored.1
        let today = Calendar.current.startOfDay(for: now)
        let games = saved.games.mapValues { $0.filter {
            ($0.isLive || $0.isUpcoming) && ($0.start >= today || now.timeIntervalSince($0.start) < 12 * 60 * 60)
        } }
        let identities = Dictionary(games.values.joined().map { ($0.id, Self.matchIdentity($0)) },
                                    uniquingKeysWith: { first, _ in first })
        let matches = saved.matches.filter { id, match in
            identities[id].map { match.isCurrent(identity: $0, now: now) } ?? false
        }
        // A schedule is useful even when every result is currently unmatched.
        // Publish it before any provider or guide work starts.
        var restoredSchedule = false
        if gamesByLeague.isEmpty, PreparedMatchPolicy.canUse(preparedAt: saved.savedAt, now: now) {
            gamesByLeague = Dictionary(uniqueKeysWithValues: games.compactMap { key, value in
                SportsLeague(rawValue: key).map { ($0, value) }
            })
            scheduleLoadedLeagues = Set(saved.loadedLeagues.compactMap(SportsLeague.init(rawValue:)))
            scheduleDay = today
            didRestoreSchedule = true
            scheduleSnapshotAt = saved.savedAt
            restoredSchedule = true
        }
        guard !matches.isEmpty else {
            #if os(iOS)
            if restoredSchedule { providerOwner?.providerContextsRevision &+= 1 }
            #endif
            return false
        }
        preparedMatches = matches
        dailyPreparedAt = saved.dailyPreparedAt
        var compactStreams: [Int: XtreamStream] = [:]
        var compactPrograms: [String: [CurrentProgram]] = [:]
        var compactCategories: [String: String] = [:]
        for match in matches.values {
            for stream in match.streams { compactStreams[stream.id] = stream }
            compactPrograms.merge(match.programs, uniquingKeysWith: { first, _ in first })
            compactCategories.merge(match.categoryNames, uniquingKeysWith: { first, _ in first })
        }
        if streams.isEmpty {
            streams = compactStreams.values.sorted { $0.id < $1.id }
            categories = compactCategories.map { XtreamCategory(categoryID: $0.key, categoryName: $0.value) }
            programsByChannel = compactPrograms
        }
        for (id, match) in matches {
            if let game = gamesByLeague.values.joined().first(where: { $0.id == id }) {
                gameStreamCache[id] = match.playbackCandidates(for: game, now: now).first
            }
            matchedGameIdentities[id] = match.identity
        }
        #if os(iOS)
        providerOwner?.providerContextsRevision &+= 1
        #endif
        StartupTrace.shared.note("prepared games playable", "\(matches.count) events; full guide not needed")
        return true
    }

    /// Upgrade an existing install without making it wait for another EPG
    /// download or a full matching pass. Only previously selected channels are
    /// checked here; the daily background pass prepares the complete alternatives.
    private func prepareRestoredPrimaryMatches(savedAt: Date) async {
        guard !gameStreamCache.isEmpty else { return }
        let generation = providerGeneration
        let games = gamesByLeague.values.flatMap { $0 }
        let selected = gameStreamCache, programs = programsByChannel, groups = categories
        let now = Date()
        let prepared = await Task.detached(priority: .utility) {
            var result: [String: PreparedLiveMatch] = [:]
            let names = Dictionary(groups.map { ($0.id, $0.matchingName) }, uniquingKeysWith: { first, _ in first })
            let board = Self.tournamentBoard(games)
            for game in games {
                guard let stream = selected[game.id], game.isLive || game.isUpcoming else { continue }
                let verified = Self.matchingEventChannels(for: game, candidates: [stream],
                    programs: programs, categories: groups, board: board, now: now)
                guard !verified.isEmpty else { continue }
                let evidence = stream.epgChannelID.map { [$0: programs[$0] ?? []] } ?? [:]
                let category = stream.categoryID.map { [$0: names[$0] ?? ""] } ?? [:]
                result[game.id] = PreparedLiveMatch(preparedAt: savedAt, eventStart: game.start,
                    identity: Self.matchIdentity(game), primary: stream, alternatives: verified,
                    programs: evidence, categoryNames: category)
            }
            return result
        }.value
        guard generation == providerGeneration else { return }
        let identities = matchIdentities(now: Date())
        for (id, entry) in prepared where identities[id] == entry.identity { preparedMatches[id] = entry }
        if !preparedMatches.isEmpty {
            persistPreparedMatches()
            await preparedWriteTask?.value
            StartupTrace.shared.note("existing matches prepared", "\(preparedMatches.count) games; no provider request")
        }
    }

    private func persistPreparedMatches() {
        #if os(iOS)
        guard combinedRoot == nil else { return }
        #endif
        guard let profile = activeProfile else { return }
        let identities = matchIdentities(now: Date())
        let snapshot = PreparedLiveSnapshot(version: PreparedLiveSnapshot.version,
            connection: PreparedLiveSnapshot.connection(for: profile), savedAt: Date(), dailyPreparedAt: dailyPreparedAt,
            games: Dictionary(uniqueKeysWithValues: gamesByLeague.map { ($0.key.rawValue, $0.value) }),
            loadedLeagues: Set(scheduleLoadedLeagues.map(\.rawValue)),
            matches: preparedMatches.filter { identities[$0.key] == $0.value.identity })
        let directory = preparedCacheDirectory
        let secret = credentials.password(profile.id)
        let sourceURLs = preparedPlaylistURLs
        let previous = preparedWriteTask
        preparedWriteTask = Task.detached(priority: .utility) {
            await previous?.value
            var saved = snapshot
            if profile.isPlaylist, let secret {
                let ids = Set(snapshot.matches.values.flatMap(\.streams).map(\.id))
                let urls = PlaylistCache.read(profileID: profile.id, secret: secret)?.urls ?? sourceURLs
                saved.playlistSources = PreparedPlaylistSources.seal(urls.filter { ids.contains($0.key) }, secret: secret)
            }
            PreparedLiveStore.write(saved, profileID: profile.id, directory: directory)
        }
    }

    /// Install new provider evidence before retiring affected matches. Other
    /// events remain playable throughout a channel/guide refresh or failure.
    private func reconcilePreparedMatches(checkGuide: Bool) {
        let available = Dictionary(streams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(categories.map { ($0.id, $0.matchingName) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for (id, saved) in preparedMatches {
            let allowed = Set(saved.streams.filter {
                saved.streamIsCurrent($0, available: available, programs: programsByChannel,
                                      categories: groups, checkGuide: checkGuide)
            }.map(\.id))
            guard allowed.count != saved.streams.count else { continue }
            changed = true
            eventsNeedingPreparation.insert(id)
            let kept = allowed.isEmpty ? nil : saved.retaining(allowed)
            preparedMatches[id] = kept
            gameStreamCache[id] = kept?.primary
            matchedGameIdentities[id] = kept?.identity
            gameMatchSignatures[id] = nil
            fastValidatedGameIDs.remove(id)
        }
        if changed {
            eventChannelCache = [:]
            persistPreparedMatches()
        }
    }

    private func refreshInBackground(topUp: Bool = false) {
        guard automaticRefreshes, backgroundRefresh == nil, !libraryRefreshInFlight,
              let profileID = activeProfile?.id else { return }
        let now = Date()
        if let attempted = lastBackgroundRefreshAttempt, attempted <= now,
           now.timeIntervalSince(attempted) < 120 { return }
        let dailyDue = PreparedMatchPolicy.needsRefresh(preparedAt: dailyPreparedAt, now: Date())
        let channelsDue = topUp || !isLibraryFresh || dailyDue
        let guideDue = topUp || !isGuideFresh || dailyDue
        guard channelsDue || guideDue || !sportsIndexReady else { return }
        lastBackgroundRefreshAttempt = now
        let requestGeneration = providerGeneration
        backgroundRefresh = Task { [weak self] in
            await self?.refreshLibrary(forceGuide: guideDue, refreshChannels: channelsDue, invalidatesSession: !topUp)
            guard let self, self.providerGeneration == requestGeneration, self.activeProfile?.id == profileID else { return }
            self.backgroundRefresh = nil
        }
    }

    /// Maintenance runs while active and on resume. Suspension never makes
    /// saved playback wait for a missed refresh.
    func refreshProviderIfNeeded() {
        guard !bootstrapInFlight, didRestoreProviderCache else { return }
        refreshInBackground()
    }

    func reload() async {
        #if os(iOS)
        if let combinedRoot {
            await MobileProviderCatalog.shared.invalidate()
            await combinedRoot.reload()
            _ = await combinedRoot.combinedGuide()
            return
        }
        #endif
        guard !isSwitchingProfile else { return }
        dailyPreparedAt = nil
        if automaticRefreshes { refreshSchedule() }
        await refreshLibrary(forceGuide: true)
    }

    // `invalidatesSession` is what makes startup withhold playback until a fetch
    // has happened this session, because providers recycle numbered event stream
    // IDs. A later top-up is replacing already validated data rather than waiting
    // for its first fetch, so it leaves that gate alone and keeps the matches up.
    private func refreshLibrary(forceGuide: Bool, refreshChannels: Bool = true,
                                invalidatesSession: Bool = true) async {
        guard !libraryRefreshInFlight,
              let profile = activeProfile, !disabledProviderIDs.contains(profile.id),
              let password = credentials.password(profile.id) else { return }
        let requestGeneration = providerGeneration
        libraryRefreshInFlight = true
        defer {
            if providerGeneration == requestGeneration {
                libraryRefreshInFlight = false
                refreshProgress.settle()
            }
            #if os(iOS)
            providerOwner?.providerContextsRevision &+= 1
            #endif
        }
        // Said in the pop-up when the app sets out to bring everything up to
        // date. A top-up behind a game about to start runs every two minutes
        // while it waits for that game's channel; announcing each of those
        // would be a pop-up that never went away.
        if invalidatesSession {
            var steps: [DataRefreshProgress.Step] = [.matching]
            if refreshChannels { steps.append(.channels) }
            if forceGuide && !isGuideLoading { steps += [.guide, .guideReading] }
            refreshProgress.plan(steps, profile: profile.id)
            #if !os(iOS)
            if channelMatchingWorkCount > 0 { refreshProgress.start(.matching) }
            #endif
        }
        if refreshChannels && invalidatesSession {
            channelsValidatedThisSession = false
            fastValidatedGameIDs = []
        }
        if forceGuide && invalidatesSession { guideValidatedThisSession = false }
        // Set only when they change: a refresh for a game still looking for
        // its channel runs every two minutes around its start, and each
        // change redraws whatever watches the library.
        let loading = refreshChannels && streams.isEmpty
        if isLoading != loading { isLoading = loading }
        if errorMessage != nil { errorMessage = nil }
        let client = XtreamClient(profile: profile, password: password, session: providerSession)
        let oldGuideRevision = guideRevision
        // One index build after both responses, with saved playback usable for
        // the entire download. Neither response starts an overlapping build.
        let guideTask = forceGuide
            ? refreshGuide(client: client, profileID: profile.id, rebuildsIndex: !refreshChannels) : nil
        guard refreshChannels else {
            await guideTask?.value
            if !sportsIndexReady { await rebuildProfessionalStreams() }
            else { await rebuildGameStreamCache() }
            return
        }
        #if os(iOS)
        let progress = refreshProgress
        let channelWork = progress.start(.channels)
        defer { progress.finish(channelWork) }
        #else
        refreshProgress.start(.channels)
        defer { if providerGeneration == requestGeneration { refreshProgress.finish(.channels) } }
        let progress = refreshProgress
        #endif
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
                // The list of channels is the bulk of this, and what the
                // percentage follows; the categories are a few kilobytes.
                async let loadedStreams = client.streams(
                    ifChangedFrom: LibraryCachePolicy.digest(streamsDigest,
                                                             whenHolding: !streams.isEmpty),
                    progress: {
                        guard self.providerGeneration == requestGeneration else { return }
                        #if os(iOS)
                        progress.download(channelWork, $0)
                        #else
                        progress.download(.channels, $0)
                        #endif
                    })
                return try await (loadedCategories, loadedStreams)
            }
            let (freshCategories, freshStreams) = answers
            // The digest saves parsing these, never downloading them, so the
            // size is recorded either way -- it is the number that says
            // whether the next thing worth doing is at the HTTP level.
            trace.note("channel list downloaded",
                       "\(StartupTrace.size(freshCategories.bytes + freshStreams.bytes)), "
                       + (freshStreams.payload == nil ? "unchanged" : "changed"))
            guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
            // Different bytes still need the old comparison: a server can
            // reorder a list, or restate it, without changing what it says.
            let oldCategories = categories
            let oldStreams = streams
            let newCategories = freshCategories.payload
            let newStreams = freshStreams.payload
            let changes = await trace.measure("compare channel list") {
                await Task.detached(priority: .utility) {
                    let oldByID = Dictionary(oldStreams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let oldGroups = Dictionary(oldCategories.map { ($0.id, $0.matchingName) }, uniquingKeysWith: { first, _ in first })
                    let groups = Dictionary((newCategories?.value ?? oldCategories).map { ($0.id, $0.matchingName) },
                                            uniquingKeysWith: { first, _ in first })
                    let changedIDs = Set((newStreams?.value ?? oldStreams).filter { fresh in
                        guard let old = oldByID[fresh.id] else { return true }
                        return !DailyCachePolicy.isSameChannelSlot(cachedID: old.id, freshID: fresh.id,
                            cachedName: old.name, freshName: fresh.name,
                            cachedEPG: old.epgChannelID, freshEPG: fresh.epgChannelID)
                            || old.categoryID != fresh.categoryID || old.streamType != fresh.streamType
                            || oldGroups[old.categoryID ?? ""] != groups[fresh.categoryID ?? ""]
                    }.map(\.id))
                    return (newCategories.map { $0.value != oldCategories } ?? false,
                            newStreams.map { $0.value != oldStreams } ?? false, changedIDs)
                }.value
            }
            guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
            if let newCategories { categoriesDigest = newCategories.digest }
            if let newStreams { streamsDigest = newStreams.digest }
            if changes.0, let newCategories { categories = newCategories.value }
            if changes.1, let newStreams {
                guideListCache = nil
                streams = newStreams.value
            }
            if changes.0 || changes.1 {
                sportsIndexReady = false
                matchGeneration = UUID()
            }
            libraryUpdatedAt = Date()
            hasFullCatalog = true
            didRestoreProviderCache = true
            if profile.isPlaylist, let playlist = PlaylistCache.read(profileID: profile.id, secret: password) {
                preparedPlaylistURLs = playlist.urls
            }
            channelsValidatedThisSession = true
            reconcilePreparedMatches(checkGuide: false)
            if isLoading { isLoading = false }
            #if os(iOS)
            // Input is now installed. Track the current index/match operations
            // separately, so an obsolete overlapping pass cannot hold this open.
            progress.finish(channelWork)
            #endif
            // Saved event playback is independent of this refresh, so both
            // responses can settle before one index/matching pass starts.
            await guideTask?.value
            guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
            if changes.0 || changes.1 || oldGuideRevision != guideRevision || !sportsIndexReady {
                await trace.measure("rebuild sports index", detail: "channel list changed",
                                    { await rebuildProfessionalStreams(changedStreamIDs: changes.2) })
            } else { await rebuildGameStreamCache() }
            guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
            if !channelsValidatedThisSession { channelsValidatedThisSession = true }
            await promoteCachedMatchesIfSafe()
            if isLoading { isLoading = false }
            saveCache(profileID: profile.id)
        } catch {
            #if os(iOS)
            progress.fail(channelWork)
            #endif
            guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
            if isLoading { isLoading = false }
            if streams.isEmpty { errorMessage = error.localizedDescription }
            await guideTask?.value
            guard providerGeneration == requestGeneration, activeProfile?.id == profile.id else { return }
            if hasFullCatalog, oldGuideRevision != guideRevision { await rebuildProfessionalStreams() }
        }
    }

    /// Returns the task doing the work, so a caller that is about to rebuild
    /// the index can wait for the guide first.
    ///
    /// The channel list and the guide arrive seconds apart, and each used to
    /// rebuild the index on arrival: two full builds per launch, the first of
    /// them thrown away by the generation token the moment the second landed.
    @discardableResult
    private func refreshGuide(client: XtreamClient, profileID: UUID,
                              rebuildsIndex: Bool = true) -> Task<Void, Never>? {
        guard !isGuideLoading else { return guideRefresh }
        let requestGeneration = providerGeneration
        isGuideLoading = true
        #if os(iOS)
        let progress = refreshProgress
        let guideWork = progress.start(.guide)
        #else
        refreshProgress.start(.guide)
        let progress = refreshProgress
        #endif
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.providerGeneration == requestGeneration, self.activeProfile?.id == profileID { self.isGuideLoading = false }
                #if os(iOS)
                progress.finish(guideWork)
                #else
                if self.providerGeneration == requestGeneration {
                    progress.finish(.guide)
                    progress.finish(.guideReading)
                }
                #endif
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
                    try await client.programsToday(ifChangedFrom: ask, progress: { update in
                        guard self.providerGeneration == requestGeneration else { return }
                        #if os(iOS)
                        progress.download(guideWork, update)
                        #else
                        progress.download(.guide, update)
                        // Once it has all arrived, what is left is reading it.
                        if update.finished {
                            progress.finish(.guide)
                            progress.start(.guideReading)
                        }
                        #endif
                    })
                }
            } catch {
                #if os(iOS)
                progress.fail(guideWork)
                #endif
                return
            }
            trace.note("guide downloaded",
                       "\(StartupTrace.size(answer.bytes)), "
                       + (answer.payload == nil ? "unchanged — not parsed" : "parsed"))
            guard self.providerGeneration == requestGeneration, self.activeProfile?.id == profileID else { return }
            var changed = false
            if let fresh = answer.payload {
                let previousPrograms = self.programsByChannel
                let programs = fresh.value
                changed = await trace.measure("compare guide") {
                    await Task.detached(priority: .utility) { previousPrograms != programs }.value
                }
                guard self.providerGeneration == requestGeneration, self.activeProfile?.id == profileID else { return }
                self.guideDigest = fresh.digest
                if changed {
                    self.programsByChannel = programs
                    self.sportsIndexReady = false
                    self.matchGeneration = UUID()
                }
                #if !os(iOS)
                progress.finish(.guideReading)
                #endif
            } else {
                // The same bytes as last time: there was nothing to read.
                #if !os(iOS)
                progress.skip(.guideReading)
                #endif
            }
            self.guideUpdatedAt = Date()
            self.hasFullGuide = true
            self.guideValidatedThisSession = true
            self.reconcilePreparedMatches(checkGuide: true)
            #if os(iOS)
            progress.finish(guideWork)
            #endif
            if changed && rebuildsIndex {
                await trace.measure("rebuild sports index", detail: "guide changed",
                                    { await self.rebuildProfessionalStreams() })
            }
            guard self.providerGeneration == requestGeneration, self.activeProfile?.id == profileID else { return }
            if !self.guideValidatedThisSession { self.guideValidatedThisSession = true }
            self.saveCache(profileID: profileID)
        }
        guideRefresh = task
        return task
    }

    private var isGuideFresh: Bool {
        guard hasFullGuide, let guideUpdatedAt else { return false }
        return Calendar.current.isDate(guideUpdatedAt, inSameDayAs: Date())
            && Date().timeIntervalSince(guideUpdatedAt) < guideLifetime
    }

    private var isLibraryFresh: Bool {
        guard hasFullCatalog, !streams.isEmpty, let libraryUpdatedAt else { return false }
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
        #if os(iOS)
        if combinedRoot != nil { return }
        #endif
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
            guideDigest: guideDigest,
            channelFormat: Self.channelFormat
        )
        lastSavedMatchIdentities = identities
        lastSavedMatchDay = now

        // Written only when they would say something new.
        var channels: ChannelCache?
        if LibraryCachePolicy.needsWriting(signature: channelsSignature, lastWritten: savedChannelsDigest) {
            var index: SportsIndex? = sportsIndexReady
                ? SportsIndex(professional: professionalStreams, leagues: leagueStreamCache) : nil
            #if os(iOS)
            index?.listingFacts = mobileIndexFacts.snapshot()
            #endif
            channels = ChannelCache(categories: categories, streams: streams, sportsIndex: index)
        }
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

    /// The last good schedule, for a cold start before the feed answers. A
    /// file, not a preference: preferences are read whole at launch and
    /// written whole on every save, and this changes with every score.
    nonisolated private static func scheduleURL() -> URL {
        cacheDirectory().appendingPathComponent("lineup-schedule.json")
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
        PlaylistCache.remove(profileID: profileID)
        let manager = FileManager.default
        for url in [cacheURL(profileID: profileID), channelsURL(profileID: profileID),
                    guideURL(profileID: profileID), stateURL(profileID: profileID)] {
            try? manager.removeItem(at: url)
        }
    }

    func streams(for league: SportsLeague) -> [XtreamStream] {
        leagueStreamCache[league] ?? []
    }

    /// For the channel picker on a tennis match: the channels showing its
    /// tournament now, then any showing tennis -- where someone choosing a
    /// different feed would look first.
    func tennisCoverage(for game: SportsGame, now: Date = Date()) -> [XtreamStream] {
        guard game.league.isTennis else { return [] }
        let tournament = Self.tournamentWords(game.tennisTournament) + Self.tournamentWords(game.tennisCity)
        var ranked: [(stream: XtreamStream, score: Int)] = []
        for stream in streams(for: game.league) {
            let name = stream.name.lowercased()
            guard !["replay", "classic", "highlights", "radio"].contains(where: name.contains) else { continue }
            let showing = (programsByChannel[stream.epgChannelID ?? ""] ?? [])
                .filter { $0.start <= now && now < $0.end }
                .map { ($0.title + " " + $0.detail).lowercased() }.joined(separator: " ")
            var score = 0
            if !tournament.isEmpty, tournament.contains(where: showing.contains) { score += 4 }
            if showing.contains("tennis") || showing.contains("atp") || showing.contains("wta") { score += 2 }
            if name.contains("tennis") { score += 1 }
            if score > 0 { ranked.append((stream, score)) }
        }
        return ranked.sorted { $0.score == $1.score ? $0.stream.id < $1.stream.id : $0.score > $1.score }
            .prefix(6).map(\.stream)
    }

    /// A listing from the archive rather than the tennis being played: a
    /// classic, a replay, highlights, a preview, or a season other than this
    /// one -- "2025 Shanghai Masters Final" in 2026. Around New Year either
    /// neighbouring season can be current: the United Cup starts in
    /// December under the next year's name.
    nonisolated static func isArchive(_ listing: ProfessionalChannelMatcher.PreparedListing,
                                      season: Int, start: Date) -> Bool {
        let archive = [" classic ", " classics ", " replay ", " encore ", " rewind ", " highlights ",
                       " best of ", " flashback ", " preview ", " review ", " recap ", " documentary ",
                       " rebroadcast ", " re air "]
        if archive.contains(where: listing.text.contains) { return true }
        let month = Calendar.current.component(.month, from: start)
        let years = listing.text.split(separator: " ").compactMap { Int($0) }.filter { (1968...2100).contains($0) }
        return years.contains { year in
            guard year != season else { return false }
            let turnOfYear = (month == 12 && year == season + 1) || (month == 1 && year == season - 1)
            return !turnOfYear
        }
    }

    /// What a listing would call a tournament: "Rolex Shanghai Masters" is
    /// "shanghai"; "US Open" has no word of its own, so it is the name.
    nonisolated static func tournamentWords(_ venue: String?) -> [String] {
        var name = (venue ?? "").components(separatedBy: " \u{00B7} ").first?.lowercased() ?? ""
        // "... presented by Ecotrans Group": the sponsor is not the event.
        if let sponsor = name.range(of: " presented by ") { name = String(name[..<sponsor.lowerBound]) }
        let common: Set<String> = ["open", "masters", "championships", "championship", "cup", "tennis", "rolex",
                                   "mutua", "presented", "classic", "international", "internationals", "grand", "prix",
                                   "trophy", "tournament", "final", "finals", "with", "the", "women", "womens",
                                   "mens", "ladies", "tour", "series", "group", "city", "citta", "della", "pace"]
        let words = name.components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !common.contains($0) }
        if !words.isEmpty { return words }
        let whole = name.trimmingCharacters(in: .whitespaces)
        return whole.isEmpty ? [] : [whole]
    }

    func games(for league: SportsLeague?) -> [SportsGame] {
        let games = league.map { gamesByLeague[$0] ?? [] } ?? SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }
        return games.filter { ($0.isLive || $0.isUpcoming) && isListed($0) }.sorted { $0.start < $1.start }
    }

    /// Whether a game has a card of its own.
    ///
    /// Every game does but tennis. A day of tennis is sixty matches on a
    /// dozen courts across several tournaments, and the channels carry
    /// tournaments, not courts. Listed as they come, most of those cards
    /// could only open the picker. So tennis lists only what will play:
    /// one card for each tournament a channel is showing, and a match of
    /// its own only where a channel names that match.
    func isListed(_ game: SportsGame) -> Bool {
        guard game.league.isTennis else { return true }
        return stream(for: game) != nil
    }

    func scoreTickerGames() -> [SportsGame] {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let games = SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }.filter(isListed)
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
        #if os(iOS)
        if let combinedRoot {
            combinedRoot.refreshSchedule(showsLoading: showsLoading, includeTomorrow: includeTomorrow)
            return
        }
        #endif
        guard !isSwitchingProfile else { return }
        refreshProviderIfNeeded()
        let today = Calendar.current.startOfDay(for: Date())
        if scheduleDay != today {
            scheduleDay = today
            // Yesterday's preparation includes today's upcoming slate. Keep
            // it and ongoing overnight games while fetching the new day.
            gamesByLeague = gamesByLeague.mapValues { $0.filter {
                $0.start >= today || ($0.isLive && Date().timeIntervalSince($0.start) < 12 * 60 * 60)
            } }
            scheduleValidatedLeagues = []
            let identities = matchIdentities(now: Date())
            gameStreamCache = gameStreamCache.filter { identities[$0.key] != nil }
            matchEvidenceScores = matchEvidenceScores.filter { identities[$0.key] != nil }
            didCompleteMatching = false
            fastValidatedGameIDs = []
            restoredMatchGameIDs = []
            gameMatchSignatures = [:]
            matchedGameIdentities = matchedGameIdentities.filter { identities[$0.key] == $0.value }
            preparedMatches = preparedMatches.filter { identities[$0.key] == $0.value.identity }
            matchGeneration = UUID()
            scheduleErrorMessage = nil
            tomorrowScheduleUpdatedAt = nil
        }
        guard !scheduleRefreshInFlight else { return }
        let profileID = activeProfile?.id
        let requestGeneration = providerGeneration
        scheduleRefreshInFlight = true
        if showsLoading { isScheduleLoading = true }
        let fetchesTomorrow = includeTomorrow
            || tomorrowScheduleUpdatedAt == nil
            || Date().timeIntervalSince(tomorrowScheduleUpdatedAt!) >= tomorrowScheduleLifetime
        Task { [weak self] in
            let snapshot = await SportsScheduleClient().gamesToday(includeTomorrow: fetchesTomorrow)
            guard let self else { return }
            defer {
                if self.providerGeneration == requestGeneration {
                    self.scheduleRefreshInFlight = false
                    if showsLoading { self.isScheduleLoading = false }
                }
            }
            guard self.providerGeneration == requestGeneration, self.activeProfile?.id == profileID else { return }
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
                            // A game the fetch did bring is never kept twice: a
                            // tennis tournament's card moves to tomorrow and back.
                            let freshIDs = Set(fresh.map(\.id))
                            let keptTomorrow = (previousGames[league] ?? [])
                                .filter { $0.start >= tomorrowStart && !freshIDs.contains($0.id) }
                            games[league] = (fresh + keptTomorrow).sorted { $0.start < $1.start }
                        }
                    }
                    return (games, games != previousGames,
                            Self.matchingInputs(games) != Self.matchingInputs(previousGames))
                }.value
                guard self.providerGeneration == requestGeneration, self.activeProfile?.id == profileID,
                      Calendar.current.isDate(today, inSameDayAs: Date()) else { return }
                if update.1 {
                    self.gamesByLeague = update.0
                    self.persistSchedule(loadedLeagues: self.scheduleLoadedLeagues.union(snapshot.loadedLeagues))
                }
                self.scheduleLoadedLeagues.formUnion(snapshot.loadedLeagues)
                self.scheduleSnapshotAt = Date()
                // A score or a clock moving can't change which channel carries a
                // game. A refresh that moved only those rematches every few
                // minutes, which still rechecks kept matches against the guide,
                // rather than every thirty seconds through a live game: each
                // pass prepares every channel's listings.
                let unprepared = self.gamesByLeague.values.joined().contains {
                    ($0.isLive || $0.isUpcoming)
                        && (self.eventsNeedingPreparation.contains($0.id) || self.preparedMatch(for: $0) == nil)
                }
                if update.2 || unprepared || self.hasUnmatchedLiveGame
                    || (update.1 && Date().timeIntervalSince(self.lastMatchingPass) >= Self.scoreOnlyRematchInterval) {
                    await self.rebuildGameStreamCache()
                }
                if !self.bootstrapInFlight, self.hasUnmatchedGameNeedingProviderData,
                   Date().timeIntervalSince(self.lastUnmatchedProviderRefresh ?? .distantPast) > 120 {
                    self.lastUnmatchedProviderRefresh = Date()
                    self.refreshInBackground(topUp: true)
                }
                guard self.providerGeneration == requestGeneration, self.activeProfile?.id == profileID else { return }
                // Set on every refresh, even unchanged: the rows that read it are
                // redrawn by it, which is what moves a game to live as its start
                // time passes when nothing in the schedule did.
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
        scheduleSnapshotAt = value.savedAt
        let location = scheduleCacheLocation ?? Self.scheduleURL()
        let previousWrite = scheduleWriteTask
        scheduleWriteTask = Task.detached(priority: .utility) {
            await previousWrite?.value
            Self.write(value, to: location)
        }
        persistPreparedMatches()
    }

    func scheduleAvailable(for league: SportsLeague?) -> Bool {
        if let league { return scheduleLoadedLeagues.contains(league) }
        return Set(SportsLeague.allCases).isSubset(of: scheduleLoadedLeagues)
    }

    /// What `eventChannels(for:)` is worked out from, for a view showing its
    /// answer that should ask again when any of it moves.
    var eventChannelsInputs: [AnyHashable] {
        var inputs: [AnyHashable] = [activeProfile?.id, profiles.map { "\($0.id)|\($0.name)|\($0.serverURL)|\($0.username)|\($0.connectionKind ?? "")" },
         disabledProviderIDs, indexGeneration, streamsRevision, guideRevision, gamesRevision,
         scheduleValidatedLeagues, didCompleteMatching, channelsValidatedThisSession,
         guideValidatedThisSession, sportsIndexReady, fastValidatedGameIDs, channelsAreSyncing,
         preparedMatchesRevision]
        #if os(iOS)
        inputs.append(providerContextsRevision)
        #endif
        return inputs
    }

    func stream(for game: SportsGame) -> XtreamStream? {
        guard eventChannelsReady(for: game) else { return nil }
        if let prepared = preparedMatch(for: game) {
            return prepared.playbackCandidates(for: game, now: Date()).compactMap { self.stream(withID: $0.id) }.first
        }
        return gameStreamCache[game.id]
    }

    func eventChannelsReady(for game: SportsGame) -> Bool {
        if let current = gamesByLeague[game.league]?.first(where: { $0.id == game.id }),
           Self.matchIdentity(current) != Self.matchIdentity(game) { return false }
        #if os(iOS)
        if combinedRoot != nil {
            return combinedProviderContexts.values.contains { $0.eventChannelsReady(for: game) }
        }
        #endif
        return preparedMatch(for: game) != nil
            || (matchIsReady(game) && scheduleValidatedLeagues.contains(game.league))
    }

    /// Reapply the list's stricter evidence to the current guide at selection.
    func isEventChannel(_ stream: XtreamStream, verifiedFor game: SportsGame) -> Bool {
        #if os(iOS)
        if let source = combinedSources[stream.id] { return source.library.isEventChannel(source.stream, verifiedFor: game) }
        if combinedRoot != nil { return false }
        #endif
        guard eventChannelsReady(for: game) else { return false }
        let category = categories.first { $0.id == (stream.categoryID ?? "") }?.matchingName ?? ""
        return Self.eventChannelScore(stream, game: game, preparedGame: Self.prepared(game),
            listings: evidencePrograms(for: stream, game: game), category: category, now: Date()) != nil
    }

    /// The event's actual matching channels, not broad league/search suggestions.
    /// Build off the main actor; a provider or guide change retires the result.
    func eventChannels(for game: SportsGame, deadline: TimeInterval? = nil) async -> [LiveEventChannel] {
        guard eventChannelsReady(for: game) else { return [] }
        let current = gamesByLeague[game.league]?.first { $0.id == game.id } ?? game
        guard current.isLive || current.isUpcoming else { return [] }
        #if os(iOS)
        if combinedRoot != nil {
            var result: [LiveEventChannel] = []
            for context in enabledProfiles.compactMap({ combinedProviderContexts[$0.id] }) {
                let found = await context.eventChannels(for: current, deadline: deadline)
                guard !Task.isCancelled else { return [] }
                result += found.compactMap { channel in
                    guard let display = displayStream(for: .init(library: context, stream: channel.stream)) else { return nil }
                    return LiveEventChannel(stream: display, program: channel.program, evidence: channel.evidence,
                                            quality: channel.quality, sharedCoverage: channel.sharedCoverage)
                }
            }
            return result
        }
        #endif
        if let prepared = preparedMatch(for: current) {
            // Only recheck the few prepared alternatives, never the full list.
            return Self.matchingEventChannels(for: current,
                candidates: prepared.alternatives.compactMap { stream(withID: $0.id) },
                programs: prepared.programs, categories: categories,
                board: Self.tournamentBoard(gamesByLeague.values.flatMap { $0 }), now: Date())
        }
        let profile = activeProfile?.id, generation = indexGeneration
        let identity = Self.matchIdentity(current)
        let cacheKey = ([profile?.uuidString ?? "", generation.uuidString, current.id] + identity).joined(separator: "|")
        let now = Date()
        eventChannelCache = eventChannelCache.filter { $0.value.expires > now }
        if let cached = eventChannelCache[cacheKey] { return cached.channels }
        var candidates = game.league == .ncaaf ? streams : streams(for: game.league)
        #if os(iOS)
        if combinedRoot != nil {
            candidates = candidates.filter { combinedSources[$0.id]?.library.automaticMatchingReady == true }
        }
        // Reuse only the conservative candidate hints from this exact guide/
        // channel index and event identity. The strict scorer below still runs.
        // Keep college channels outside its ordinary pool: the full Channels
        // policy may consider them even when automatic college matching did not.
        if let snapshot = mobileEventCandidates, snapshot.generation == generation,
           snapshot.identities[current.id] == identity, let possible = snapshot.games[current.id] {
            candidates = candidates.filter {
                possible.contains($0.id) || (current.league == .ncaaf && !snapshot.collegePool.contains($0.id))
            }
        }
        #endif
        let programs = programsByChannel, groups = categories
        let board = current.league.isTennis && current.isEvent
            ? Self.tournamentBoard(SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }) : []
        let work = Task.detached(priority: .userInitiated) {
            Self.matchingEventChannels(for: current, candidates: candidates, programs: programs,
                categories: groups, board: board, now: Date(), deadline: deadline)
        }
        let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        guard !Task.isCancelled, activeProfile?.id == profile, indexGeneration == generation,
              Self.matchIdentity(gamesByLeague[game.league]?.first { $0.id == game.id } ?? game) == identity,
              eventChannelsReady(for: current) else { return [] }
        // Partial deadline-limited discovery is only for a quick automatic
        // selection. The Channels menu must still get its complete results.
        if deadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true {
            if eventChannelCache.count >= 32 { eventChannelCache.removeAll() }
            let boundary = result.compactMap { $0.program?.end }.filter { $0 > now }.min()
            let expires = min(min(now.addingTimeInterval(15), boundary ?? now.addingTimeInterval(15)),
                current.isUpcoming ? current.start : now.addingTimeInterval(15))
            eventChannelCache[cacheKey] = (result, expires)
        }
        return result
    }

    /// Only automatic event playback calls this. Manual and team preferences
    /// remain explicit choices; unrelated channels never enter the probe list.
    func bestQualityStream(for game: SportsGame, fallback: XtreamStream) async -> XtreamStream? {
        if let prepared = preparedPlaybackStream(for: game) { return prepared }
        #if os(iOS)
        guard providerConnectionAvailable else { return nil }
        if let source = combinedSources[fallback.id] {
            guard source.library.providerConnectionAvailable else { return nil }
            guard let chosen = await source.library.bestQualityStream(for: game, fallback: source.stream) else { return nil }
            guard source.library.providerConnectionAvailable else { return nil }
            return displayStream(for: MobileProviderPlaybackSource(library: source.library, stream: chosen))
        }
        if combinedRoot != nil { return nil }
        #endif
        // Event discovery reads the current catalog, not video inputs. Quality
        // selection itself uses only sources confirmed by real playback.
        let deadline = ProcessInfo.processInfo.systemUptime + LiveQualityVerifier.startupBudget
        let profileID = activeProfile?.id
        let identity = Self.matchIdentity(game)
        let found = await eventChannels(for: game, deadline: deadline)
        guard !Task.isCancelled, activeProfile?.id == profileID else { return nil }
        let groups = Dictionary(categories.map { ($0.id, $0.matchingName) }, uniquingKeysWith: { first, _ in first })
        func foreign(_ channel: LiveEventChannel) -> Bool {
            ChannelLanguage.isForeign(name: channel.stream.name, category: groups[channel.stream.categoryID ?? ""] ?? "")
        }
        // A tournament's own channel is measured, not one it shares, which
        // may be on another court -- in the order `ranksAhead` gives them.
        let channels = found.filter { channel in
            !channel.sharedCoverage || !found.contains { !$0.sharedCoverage && (!foreign($0) || foreign(channel)) }
        }
        #if os(iOS)
        StartupTrace.shared.note("quality discovery", "\(channels.count) verified channels; playback-confirmed cache only, no startup video probes")
        #endif
        let context = ([profileID?.uuidString ?? ""] + identity).joined(separator: "|")
        let now = Date()
        let candidates = channels.map { channel in
            LiveQualityVerifier.Candidate(id: channel.stream.id, urls: sourcePlaybackURLs(for: channel.stream),
                context: context + "|" + programs(for: channel.stream).filter { $0.start <= now && $0.end > now }
                    .map { "\($0.title)|\($0.start.timeIntervalSince1970)" }.joined(separator: "|"),
                languageRank: ChannelLanguage.isForeign(name: channel.stream.name,
                    category: groups[channel.stream.categoryID ?? ""] ?? "") ? 1 : 0,
                advertisedHeight: channel.quality.height)
        }
        let selection = await LiveQualityVerifier.shared.preferredPlayback(candidates, fallback: fallback.id)
        var selected = selection.streamID
        #if os(iOS)
        StartupTrace.shared.note("quality selection", "\(channels.count) verified event channels; selected ID \(selected), measured \(selection.quality?.label ?? "unknown"), URL variant \(selection.urlIndex.map(String.init) ?? "fallback")")
        #endif
        let current = gamesByLeague[game.league]?.first { $0.id == game.id } ?? game
        guard !Task.isCancelled, !selection.wasCancelled, activeProfile?.id == profileID,
              current.isLive, Self.matchIdentity(current) == identity else { return nil }
        #if os(iOS)
        guard providerConnectionAvailable else { return nil }
        #endif
        // A new index generation alone is not a rejection. Revalidate the
        // exact source and event now, and fall back if a cached upgrade retired.
        let choice = stream(withID: selected)
        let allowed = choice.map { selected == fallback.id
            ? isStream($0, verifiedFor: current)
            : isEventChannel($0, verifiedFor: current) } ?? false
        if !allowed {
            guard let fallbackStream = stream(withID: fallback.id),
                  isStream(fallbackStream, verifiedFor: current) else { return nil }
            selected = fallback.id
        }
        guard let stream = stream(withID: selected) else { return nil }
        measuredPlaybackURLs = measuredPlaybackURLs.filter { $0.value.expires > Date() }
        if selected == selection.streamID, let index = selection.urlIndex, let candidate = candidates.first(where: { $0.id == selected }),
           candidate.urls.indices.contains(index) {
            measuredPlaybackURLs["\(profileID?.uuidString ?? "")|\(selected)"] =
                (candidate.urls[index], Date().addingTimeInterval(600))
        } else {
            measuredPlaybackURLs.removeValue(forKey: "\(profileID?.uuidString ?? "")|\(selected)")
        }
        gameStreamCache[game.id] = stream
        if let channel = channels.first(where: { $0.id == selected }) { matchEvidenceScores[game.id] = channel.evidence }
        return stream
    }

    // Which rule authorized a match, for the diagnostics screen. A wrong game
    // should be able to name the evidence behind it without a device log.
    enum MatchEvidence: String {
        case dedicatedFeed = "Channel is named for this game"
        case guideListing = "Guide listing named both teams"
        case playersListing = "Guide listing named both players"
        case tournamentListing = "Guide listing names this tournament"
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
        if game.league.isTennis {
            if score >= 400 { return .dedicatedFeed }
            return score >= 300 ? .playersListing : .tournamentListing
        }
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

    /// How often a refresh that moved only scores and clocks rematches.
    private static let scoreOnlyRematchInterval: TimeInterval = 5 * 60

    /// Each game as channel matching reads it: everything but what moves
    /// while it is played -- the score, the clock, a match's sets, a race's
    /// order. A college game's clock counts only as far as saying it is
    /// delayed, which its matcher reads.
    nonisolated private static func matchingInputs(_ games: [SportsLeague: [SportsGame]]) -> [String: [String]] {
        var inputs: [String: [String]] = [:]
        for game in games.values.joined() {
            inputs[game.id] = matchIdentity(game) + [
                game.state, game.venue ?? "", game.location ?? "",
                game.race.map { [$0.eventID, $0.title, $0.circuit ?? ""].joined(separator: "|") } ?? "",
                game.league == .ncaaf && collegeMatchup(game).isDelayed ? "delayed" : ""
            ]
        }
        return inputs
    }

    /// What a kept match is kept for: change any of it and the game is
    /// looked for again. A college game's also says whether it is delayed,
    /// which widens what its matcher accepts.
    nonisolated private static func matchSignature(_ game: SportsGame) -> String {
        if game.league == .ncaaf {
            return (["college-v1"] + matchIdentity(game)
                    + [collegeMatchup(game).isDelayed ? "delayed" : ""]).joined(separator: "|")
        }
        return "quality-v1|\(game.league.rawValue)|\(game.awayTeam)|\(game.homeTeam)|\(game.broadcast)"
    }

    nonisolated private static func matchIdentity(_ game: SportsGame) -> [String] {
        PreparedLiveMatch.identity(for: game)
    }

    // Only playback actions revalidate. Row rendering must remain a cheap lookup.
    func verifiedStream(for game: SportsGame) -> XtreamStream? {
        guard eventChannelsReady(for: game) else { return nil }
        #if os(iOS)
        if combinedRoot != nil {
            for profile in enabledProfiles {
                guard let context = combinedProviderContexts[profile.id],
                      let native = context.verifiedStream(for: game),
                      let id = combinedDisplayIDs[.init(providerID: profile.id, streamID: native.id)],
                      let displayed = stream(withID: id) else { continue }
                return displayed
            }
            return nil
        }
        #endif
        let candidates: [XtreamStream]
        if let prepared = preparedMatch(for: game) {
            candidates = prepared.playbackCandidates(for: game, now: Date())
        } else {
            guard matchedGameIdentities[game.id] == Self.matchIdentity(game) else { return nil }
            candidates = gameStreamCache[game.id].map { [$0] } ?? []
        }
        for saved in candidates {
            guard let current = stream(withID: saved.id),
                  DailyCachePolicy.isSameChannelSlot(cachedID: saved.id, freshID: current.id,
                    cachedName: saved.name, freshName: current.name,
                    cachedEPG: saved.epgChannelID, freshEPG: current.epgChannelID),
                  Self.carriesGame(current, game: game,
                    listings: evidencePrograms(for: current, game: game), now: Date()) else { continue }
            return current
        }
        return nil
    }

    /// This reads only already prepared results. Live taps use it directly;
    /// channel discovery and quality selection belong to background preparation.
    func preparedPlaybackStream(for game: SportsGame) -> XtreamStream? {
        #if os(iOS)
        if combinedRoot != nil {
            for profile in enabledProfiles {
                guard let context = combinedProviderContexts[profile.id],
                      let native = context.preparedPlaybackStream(for: game),
                      let id = combinedDisplayIDs[.init(providerID: profile.id, streamID: native.id)],
                      let displayed = stream(withID: id) else { continue }
                return displayed
            }
            return nil
        }
        #endif
        guard preparedMatch(for: game) != nil else { return nil }
        return verifiedStream(for: game)
    }

    /// Use a saved, working game channel first, then the verified daily match.
    /// The exact-game selection is provider-scoped and expires with the game.
    func resolvedStream(for game: SportsGame) -> XtreamStream? {
        if let saved = gameChannelSelections.selection(for: game.id),
           let stream = stream(withID: saved.streamID), stream.name == saved.channelName { return stream }
        return verifiedStream(for: game)
    }

    /// Does current evidence say this channel is carrying this game?
    ///
    /// The single question behind every automatic playback decision. Lineup's
    /// own match asks it through `verifiedStream(for:)`, a saved team preference
    /// asks it before being honoured, and failover asks it before adding a
    /// channel to its plan — all with the same rules, so a preference can never
    /// take a weaker path to playback than an automatic match would.
    func isStream(_ stream: XtreamStream, verifiedFor game: SportsGame) -> Bool {
        #if os(iOS)
        if let source = combinedSources[stream.id] { return source.library.isStream(source.stream, verifiedFor: game) }
        if combinedRoot != nil { return false }
        #endif
        guard eventChannelsReady(for: game), let current = self.stream(withID: stream.id),
              DailyCachePolicy.isSameChannelSlot(cachedID: stream.id, freshID: current.id,
                cachedName: stream.name, freshName: current.name,
                cachedEPG: stream.epgChannelID, freshEPG: current.epgChannelID) else { return false }
        return Self.carriesGame(current, game: game, listings: evidencePrograms(for: current, game: game), now: Date())
    }

    private func evidencePrograms(for stream: XtreamStream, game: SportsGame) -> [CurrentProgram] {
        if let prepared = preparedMatch(for: game), prepared.streams.contains(where: { $0.id == stream.id }) {
            return prepared.programs[stream.epgChannelID ?? ""] ?? []
        }
        return programs(for: stream)
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
        if game.league == .soccer { return ExpandedSportsChannelMatcher.soccer(game) }
        return ProfessionalChannelMatcher.prepare(
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
        if game.league == .ncaaf {
            return CollegeChannelMatcher.score(channel: stream.name, listings: Self.collegeListings(listings),
                game: Self.collegeMatchup(game), now: now, allowNetworkFallback: false)
        }
        if game.isNFLRedZone {
            return NFLRedZoneChannelMatcher.score(channel: stream.name)
        }
        if game.league == .soccer {
            return ExpandedSportsChannelMatcher.soccerScore(channel: channel, prepared: preparedGame, game: game, now: now)
        }
        if game.league.isRacing {
            return ExpandedSportsChannelMatcher.racingScore(channel: channel, game: game, now: now)
        }
        if game.league == .ufc {
            return ufcScore(channel: stream.name, listings: listings, game: game, now: now)
        }
        if game.league.isTennis {
            return tennisScore(channel: channel, game: game, now: now)
        }
        let score = ProfessionalChannelMatcher.score(channel: channel, game: preparedGame, now: now)
        if game.league == .nhl {
            return NHLChannelPolicy.adjustedScore(score, channel: stream.name,
                                                  broadcast: game.broadcast)
        }
        return score
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

    /// Which channel carries a tennis card.
    ///
    /// A match:
    /// - 400: the channel is named for the match -- a provider's event feed,
    ///   "ESPN+ 07: Sinner vs Alcaraz" -- and its guide says nothing else.
    /// - 300: the listing on now names both players.
    ///
    /// A tournament's card (see `SportsScheduleClient.tennisEventCards`):
    /// - 220 / 200: the listing on now is that tournament's tennis, named in
    ///   its title or only in its detail. A tennis broadcast follows a
    ///   tournament -- "Center Court Live: Shanghai", "Live Tennis: WTA
    ///   Wuhan Open" -- the way a team's game is on its network. A channel
    ///   given over to that one tournament comes ahead of a show naming it
    ///   in passing.
    nonisolated static func tennisScore(channel: String, listings: [CurrentProgram],
                                        game: SportsGame, now: Date) -> Int? {
        tennisScore(channel: ProfessionalChannelMatcher.prepare(
            channel: channel,
            listings: ProfessionalChannelMatcher.prepare(
                listings.map { .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end) })),
            game: game, now: now)
    }

    /// The same, on a channel the matching pass has already prepared: its
    /// name and listings normalized once, rather than once for each of the
    /// day's sixty matches.
    nonisolated static func tennisScore(channel: ProfessionalChannelMatcher.PreparedChannel,
                                        game: SportsGame, now: Date) -> Int? {
        // Replays, highlights, radio and whip-around feeds are never a match.
        guard channel.eligible else { return nil }
        let current = currentTennisListings(channel.listings, game: game, now: now)
        // A tournament's card is played on the channel showing the
        // tournament; a match, only on one that names it.
        if game.isEvent {
            return tournamentScore(current, channel: channel, tournament: game.tennisTournament, city: game.tennisCity)
        }
        // Surnames, as a listing writes them: "Sinner v Alcaraz", "de Minaur".
        func surname(_ abbreviation: String, _ name: String) -> String {
            ProfessionalChannelMatcher.normalize(abbreviation.isEmpty ? name : abbreviation)
        }
        let away = surname(game.awayAbbreviation, game.awayTeam)
        let home = surname(game.homeAbbreviation, game.homeTeam)
        guard !away.isEmpty, !home.isEmpty, away != home else { return nil }
        let paddedAway = ProfessionalChannelMatcher.pad(away), paddedHome = ProfessionalChannelMatcher.pad(home)
        func namesBoth(_ padded: String) -> Bool { padded.contains(paddedAway) && padded.contains(paddedHome) }
        let listingConfirms = current.contains { namesBoth($0.text) }
        // A feed named for the match, with a guide that says nothing else.
        let guideSilent = current.isEmpty || current.allSatisfy {
            ["", "live", "tennis", "live tennis", "no program information"].contains($0.title) && $0.detail.isEmpty
        }
        if namesBoth(channel.padded) && (listingConfirms || guideSilent) { return 400 }
        return listingConfirms ? 300 : nil
    }

    /// What is on a channel when a tennis card plays, less anything from the
    /// archive: a classic final names the same players and the same
    /// tournament.
    nonisolated private static func currentTennisListings(_ listings: [ProfessionalChannelMatcher.PreparedListing],
                                                          game: SportsGame, now: Date) -> [ProfessionalChannelMatcher.PreparedListing] {
        let point = game.isLive ? now : max(now, game.start)
        let year = Calendar.current.component(.year, from: game.start)
        return listings.filter {
            $0.start <= point && point < $0.end && !isArchive($0, season: year, start: game.start)
        }
    }

    /// A tournament by the words a listing would use for it, padded for a
    /// word search: its own ("Shanghai"), or its city, for one whose name a
    /// guide does not use -- the Internazionali BNL d'Italia is "Rome" in a
    /// listing.
    nonisolated static func paddedTournament(_ name: String?, city: String?) -> [String] {
        (tournamentWords(name) + tournamentWords(city))
            .map { ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize($0)) }
            .filter { $0.count > 2 }
    }

    /// Every tournament with a card, as `paddedTournament` gives it: what a
    /// listing can name besides the one a card is for.
    nonisolated static func tournamentBoard(_ games: [SportsGame]) -> [[String]] {
        var board: [[String]] = []
        for game in games where game.league.isTennis && game.isEvent {
            let words = paddedTournament(game.tennisTournament, city: game.tennisCity)
            if !words.isEmpty, !board.contains(words) { board.append(words) }
        }
        return board
    }

    /// Whether a listing takes turns between tournaments: it names another
    /// one on the board, or three tours' tags at once -- "Center Court Live:
    /// Brussels-ATP, Lyon-ATP, Almaty-ATP, Osaka-WTA & Ningbo-WTA Early
    /// Rounds". The picture is on any one of them at a time.
    nonisolated private static func takesTurns(_ listing: ProfessionalChannelMatcher.PreparedListing,
                                               others: [[String]]) -> Bool {
        let tags = listing.title.split(separator: " ").filter { $0 == "atp" || $0 == "wta" }.count
        return tags >= 3 || others.contains { $0.contains(where: listing.text.contains) }
    }

    /// Whether a tournament's card has this channel only shared with other
    /// tournaments: every listing on now that names it names others too.
    /// A channel on the tournament alone is the surer place for it -- the
    /// shared one may be on another tournament's court -- so it is offered
    /// first (see `ranksAhead`).
    nonisolated static func sharesCoverage(_ channel: ProfessionalChannelMatcher.PreparedChannel,
                                           game: SportsGame, board: [[String]], now: Date) -> Bool {
        guard game.league.isTennis, game.isEvent else { return false }
        let own = paddedTournament(game.tennisTournament, city: game.tennisCity)
        guard !own.isEmpty else { return false }
        // The same tournament on the other tour's board is not another one.
        let others = board.filter { Set($0).isDisjoint(with: own) }
        let naming = currentTennisListings(channel.listings, game: game, now: now)
            .filter { listing in own.contains(where: listing.text.contains) }
        return !naming.isEmpty && naming.allSatisfy { takesTurns($0, others: others) }
    }

    /// What a tournament's card is showing on a channel it shares: the
    /// show, and how many tournaments take turns on it -- "Center Court
    /// Live · 5 tournaments" -- rather than one tournament's name over
    /// another's match. A listing whose own title names them is used as it
    /// stands. Nil for a channel on the tournament alone, and for every
    /// other card.
    nonisolated static func sharedCoverageTitle(channel: String, listings: [CurrentProgram], game: SportsGame,
                                                board: [[String]], now: Date) -> String? {
        let prepared = ProfessionalChannelMatcher.prepare(listings.map {
            .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end)
        })
        guard sharesCoverage(ProfessionalChannelMatcher.prepare(channel: channel, listings: prepared),
                             game: game, board: board, now: now) else { return nil }
        let own = paddedTournament(game.tennisTournament, city: game.tennisCity)
        guard let index = prepared.indices.first(where: { index in
            own.contains(where: prepared[index].text.contains)
                && !currentTennisListings([prepared[index]], game: game, now: now).isEmpty
        }) else { return nil }
        let listing = prepared[index]
        let title = listings[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
        let show = title.split(separator: ":", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let showPadded = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(show))
        if !show.isEmpty, own.contains(where: showPadded.contains) { return title }
        let tags = listing.title.split(separator: " ").filter { $0 == "atp" || $0 == "wta" }.count
        let named = board.filter { Set($0).isDisjoint(with: own) && $0.contains(where: listing.text.contains) }.count + 1
        let count = "\(max(tags, named, 2)) tournaments"
        return show.isEmpty ? count : "\(show) \u{00B7} \(count)"
    }

    /// A tournament on now: its tennis, named in the listing's title (220)
    /// or only in its detail (200), and a little less where the listing is
    /// both tours' coverage shared.
    nonisolated private static func tournamentScore(_ current: [ProfessionalChannelMatcher.PreparedListing],
                                                    channel: ProfessionalChannelMatcher.PreparedChannel,
                                                    tournament name: String?, city: String?) -> Int? {
        let tournament = paddedTournament(name, city: city)
        guard !tournament.isEmpty else { return nil }
        let tennisChannel = channel.padded.contains(" tennis ")
        var best: Int?
        for listing in current where tournament.contains(where: listing.text.contains) {
            // "Shanghai" in a newscast is not the tennis: the channel has to
            // be a tennis channel, or the listing has to say it is tennis.
            guard tennisChannel || [" tennis ", " atp ", " wta "].contains(where: listing.text.contains) else { continue }
            let inTitle = tournament.contains(where: ProfessionalChannelMatcher.pad(listing.title).contains)
            // "ATP Shanghai & WTA Wuhan" is two tournaments' coverage taking
            // turns; a channel on this one alone is the surer place for it.
            let shared = listing.text.contains(" atp ") && listing.text.contains(" wta ")
            best = max(best ?? 0, (inTitle ? 220 : 200) - (shared ? 10 : 0))
        }
        return best
    }

    nonisolated private static func matchedStream(for game: SportsGame, candidates: [XtreamStream],
                                                  programs: [String: [CurrentProgram]],
                                                  channels: [Int: ProfessionalChannelMatcher.PreparedChannel],
                                                  preparedGame: ProfessionalChannelMatcher.PreparedGame,
                                                  foreign: Set<Int> = [],
                                                  qualities: [Int: LiveChannelQuality] = [:],
                                                  board: [[String]] = [],
                                                  now: Date) -> XtreamStream? {
        var best: (stream: XtreamStream, score: Int)?
        var shared: Set<Int> = []
        for candidate in candidates {
            guard let prepared = channels[candidate.id] else { continue }
            guard let score = professionalScore(candidate, game: game, preparedGame: preparedGame,
                channel: prepared, listings: programs[candidate.epgChannelID ?? ""] ?? [],
                now: now) else { continue }
            if sharesCoverage(prepared, game: game, board: board, now: now) { shared.insert(candidate.id) }
            if let current = best {
                guard Self.ranksAhead((candidate.id, score), of: (current.stream.id, current.score),
                                      foreign: foreign, qualities: qualities, shared: shared) else { continue }
            }
            best = (candidate, score)
        }
        return best?.stream
    }

    /// Which of two channels carrying a game is offered first: one in English
    /// before one in another language, then a tennis tournament's channel to
    /// itself before one it shares (`shared`, see `sharesCoverage`), then
    /// advertised resolution/frame rate, evidence strength, and stable
    /// provider order. Only verified feeds enter.
    nonisolated static func ranksAhead(_ channel: (id: Int, score: Int), of other: (id: Int, score: Int),
                                       foreign: Set<Int>, qualities: [Int: LiveChannelQuality] = [:],
                                       shared: Set<Int> = []) -> Bool {
        let english = !foreign.contains(channel.id), otherEnglish = !foreign.contains(other.id)
        if english != otherEnglish { return english }
        // Whatever either's picture: a shared one may be on another court.
        let alone = !shared.contains(channel.id), otherAlone = !shared.contains(other.id)
        if alone != otherAlone { return alone }
        let quality = qualities[channel.id] ?? .unknown, otherQuality = qualities[other.id] ?? .unknown
        if quality != otherQuality { return quality > otherQuality }
        if channel.score != other.score { return channel.score > other.score }
        return channel.id < other.id
    }

    nonisolated private static let eventChannelTeams: [SportsLeague: [EventChannelEvidence.Team]] = {
        let clubCompetitions: Set<String> = ["eng.1", "esp.1", "ger.1", "ita.1", "fra.1", "usa.1", "usa.nwsl",
            "uefa.champions", "uefa.europa", "uefa.europa.conf"]
        let professional: Set<SportsLeague> = [.nba, .nfl, .nhl, .mlb]
        let teams = SportsTeamDirectory.bundled.teams.filter { team in
            // Country names can identify a broadcaster's region. Only club
            // identities are negative evidence for soccer channel names.
            team.league != .soccer || !Set(team.competitions ?? []).isDisjoint(with: clubCompetitions)
        }
        return Dictionary(grouping: teams, by: \.league).mapValues { entries in
            entries.map { team in
                EventChannelEvidence.Team(name: team.name, abbreviation: team.abbreviation,
                    nicknames: professional.contains(team.league))
            }
        }
    }()

    nonisolated private static func eventChannelScore(_ stream: XtreamStream, game: SportsGame,
                                                      preparedGame: ProfessionalChannelMatcher.PreparedGame,
                                                      listings: [CurrentProgram], category: String, now: Date) -> Int? {
        guard !["radio", "radio_streams", "movie", "series", "episode", "video", "vod"]
            .contains(stream.streamType?.lowercased() ?? "") else { return nil }
        func score(_ entries: [CurrentProgram]) -> Int? {
            let channel = ProfessionalChannelMatcher.prepare(channel: stream.name,
                listings: ProfessionalChannelMatcher.prepare(entries.map {
                    .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end)
                }))
            return Self.professionalScore(stream, game: game, preparedGame: preparedGame,
                channel: channel, listings: entries, now: now)
        }
        guard let evidence = score(listings) else { return nil }
        if game.league == .soccer {
            let women = ["fifa.wwc", "usa.nwsl"].contains(game.competition?.id ?? "")
            guard EventChannelEvidence.allowsSoccerContext(stream.name + " " + category, women: women) else { return nil }
        }
        if let race = game.race {
            guard EventChannelEvidence.allowsRacingSession(stream.name, session: race.title) else { return nil }
        }
        let teams = eventChannelTeams[game.league] ?? []
        let participants = Set(preparedGame.away + preparedGame.home)
        if !game.isEvent, !game.league.isRacing,
           !preparedGame.away.isEmpty, !preparedGame.home.isEmpty,
           EventChannelEvidence.namesMatchup(stream.name) {
            let name = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(stream.name))
            guard preparedGame.away.contains(where: name.contains),
                  preparedGame.home.contains(where: name.contains) else { return nil }
        }
        guard EventChannelEvidence.allowsSource(league: game.league.rawValue, channel: stream.name,
            category: category, date: game.start, participants: participants, teams: teams) else { return nil }
        let point = game.isLive ? now : game.start
        let current = listings.filter { $0.end > $0.start && $0.start <= point && point < $0.end }
        // A truly guide-free, explicit event feed remains usable. An expired
        // guide is not evidence of what an old event-channel name carries now.
        guard !current.isEmpty else { return listings.isEmpty ? evidence : nil }
        for program in current {
            guard EventChannelEvidence.allowsProgram(title: program.title, detail: program.detail,
                league: game.league.rawValue, date: game.start), score([program]) != nil else { return nil }
            if EventChannelEvidence.isGenericTitle(program.title, league: game.league.rawValue) {
                let detail = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(program.detail))
                guard !EventChannelEvidence.hasOtherTeam(in: detail, participants: participants, teams: teams) else { return nil }
            } else {
                // Mentions in a synopsis cannot turn an unrelated titled show
                // into this event. Preserve the original description's vetoes.
                let titleOnly = CurrentProgram(channelID: program.channelID, title: program.title,
                    detail: "", start: program.start, end: program.end)
                guard score([titleOnly]) != nil else { return nil }
            }
        }
        return evidence
    }

    nonisolated static func matchingEventChannels(for game: SportsGame, candidates: [XtreamStream],
                                                  programs: [String: [CurrentProgram]], categories: [XtreamCategory],
                                                  board: [[String]] = [],
                                                  now: Date, deadline: TimeInterval? = nil) -> [LiveEventChannel] {
        let prepared = Self.prepared(game)
        let groups = Dictionary(categories.map { ($0.id, $0.matchingName) }, uniquingKeysWith: { first, _ in first })
        var result: [LiveEventChannel] = []
        var seen: Set<Int> = []
        #if os(iOS)
        var categoryEligibility: [String: Bool] = [:]
        #endif
        for stream in candidates {
            guard !Task.isCancelled else { return [] }
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { break }
            guard seen.insert(stream.id).inserted else { continue }
            #if os(iOS)
            let categoryID = stream.categoryID ?? ""
            if categoryEligibility[categoryID] == nil {
                // Category vetoes are independent of the channel/guide. Check
                // once before preparing an excluded pool's thousands of feeds.
                categoryEligibility[categoryID] = EventChannelEvidence.allowsSource(
                    league: game.league.rawValue, channel: "", category: groups[categoryID] ?? "",
                    date: game.start, participants: [], teams: [])
            }
            guard categoryEligibility[categoryID] == true else { continue }
            #endif
            let listings = programs[stream.epgChannelID ?? ""] ?? []
            guard let score = Self.eventChannelScore(stream, game: game, preparedGame: prepared,
                listings: listings, category: groups[stream.categoryID ?? ""] ?? "", now: now) else { continue }
            let point = game.isLive ? now : game.start
            let program = listings.first { $0.start <= point && point < $0.end }
            let shared = game.league.isTennis && game.isEvent && sharesCoverage(
                ProfessionalChannelMatcher.prepare(channel: stream.name, listings: ProfessionalChannelMatcher.prepare(
                    listings.map { .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end) })),
                game: game, board: board, now: now)
            result.append(.init(stream: stream, program: program, evidence: score, quality: .init(name: stream.name),
                                sharedCoverage: shared))
        }
        let foreign = Set(result.filter { ChannelLanguage.isForeign(name: $0.stream.name,
            category: groups[$0.stream.categoryID ?? ""] ?? "") }.map(\.id))
        let qualities = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.quality) })
        let shared = Set(result.filter(\.sharedCoverage).map(\.id))
        return result.sorted { ranksAhead(($0.id, $0.evidence), of: ($1.id, $1.evidence), foreign: foreign,
                                          qualities: qualities, shared: shared) }
    }

    /// Match today's games to channels.
    ///
    /// iOS stops superseded work instead of queuing full passes or allowing
    /// stale passes to consume CPU until their result is rejected. Generation
    /// and provider checks still protect publication on both platforms.
    private func rebuildGameStreamCache(force: Bool = false) async {
        // A schedule response may arrive before startup/index rebuilding finishes.
        // The completed index rebuild will match the latest schedule itself.
        guard sportsIndexReady else { return }
        let now = Date()
        let allGames = SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }
        let dailyDue = channelsValidatedThisSession && guideValidatedThisSession
            && PreparedMatchPolicy.needsRefresh(preparedAt: dailyPreparedAt, now: now)
        let games = allGames.filter { game in
            guard game.isLive || game.isUpcoming else { return false }
            if eventsNeedingPreparation.contains(game.id) { return true }
            guard !dailyDue, let saved = preparedMatch(for: game, now: now) else { return true }
            if saved.primary != nil || !saved.alternatives.isEmpty { return false }
            let nearStart = abs(now.timeIntervalSince(game.start)) < ProviderRefreshPolicy.window
            return now.timeIntervalSince(saved.preparedAt) >= (nearStart ? 120 : Self.scoreOnlyRematchInterval)
        }
        guard !games.isEmpty else {
            if dailyDue { dailyPreparedAt = now; persistPreparedMatches() }
            return
        }
        lastMatchingPass = Date()
        channelMatchingWorkCount += 1
        defer { channelMatchingWorkCount -= 1 }
        let generation = UUID()
        matchGeneration = generation
        #if os(iOS)
        let progress = refreshProgress
        let matchingWork = progress.start(.matching)
        defer { progress.finish(matchingWork) }
        #endif
        let profileID = activeProfile?.id
        #if os(iOS)
        let sourceGeneration = indexGeneration
        #endif
        let leagues = leagueStreamCache
        let trace = StartupTrace.shared
        let listings = programsByChannel
        // College event channels may have neither a league token nor a network
        // name. Let the college policy inspect them without changing other indexes.
        let currentStreams = streams
        let currentCategories = categories
        let identities = matchIdentities(now: now)
        let previousMatches = gameStreamCache
        let previousEvidence = matchEvidenceScores
        let previousPrepared = preparedMatches
        // Invalidate signatures immediately so an overlapping schedule update also
        // rematches against a newly installed channel index.
        if force { gameMatchSignatures = [:] }
        let previousSignatures = gameMatchSignatures
        #if os(iOS)
        // The candidate shortlists the last pass worked out, while the channel
        // list and guide they came from are still the ones in use. A game
        // whose identity has not changed gets the same shortlist -- or one a
        // little longer, as listings end -- so it is carried, rather than
        // every guide the provider has being read again to rebuild it.
        let carriedShortlists = mobileEventCandidates.flatMap { snapshot in
            snapshot.generation == sourceGeneration ? (identities: snapshot.identities, games: snapshot.games) : nil
        }
        #endif
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            // Timed in two halves. The detail above counts only the league
            // buckets, and four rounds of tuning went into the half they
            // describe while the other half -- college, which casts its net
            // over every channel the provider has -- went unmeasured.
            var collegeSeconds = 0.0
            var professionalSeconds = 0.0
            func clock() -> Double { ProcessInfo.processInfo.systemUptime }

            // Everything below is read for a channel the first time the pass
            // needs it, and once. A pass that keeps every match reads the
            // kept channels' guides and no others; the first pass for a
            // channel list and guide still reads them all, building the
            // shortlists.
            //
            // Listings that have already finished are kept now, because the
            // Guide draws an hour of history and cannot show what was thrown
            // away. The matchers were never given them: the parser used to
            // drop them before anything saw them, and a matcher handed a
            // listing that ended an hour ago can credit a channel for a game
            // that is no longer on it. Matching sees exactly what it always saw.
            var currentGuides: [String: [CurrentProgram]] = [:]
            func guide(_ key: String) -> [CurrentProgram] {
                if let known = currentGuides[key] { return known }
                let entries = (listings[key] ?? []).filter { $0.end > now }
                currentGuides[key] = entries
                return entries
            }
            var preparedGuides: [String: [ProfessionalChannelMatcher.PreparedListing]] = [:]
            func preparedGuide(_ key: String) -> [ProfessionalChannelMatcher.PreparedListing] {
                if let known = preparedGuides[key] { return known }
                let prepared = ProfessionalChannelMatcher.prepare(guide(key).map {
                    .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end)
                })
                preparedGuides[key] = prepared
                return prepared
            }
            // A channel's name and listings normalized once for the pass
            // rather than once for each of sixty-six games.
            var preparedChannels: [Int: ProfessionalChannelMatcher.PreparedChannel] = [:]
            func preparedChannel(_ stream: XtreamStream) -> ProfessionalChannelMatcher.PreparedChannel {
                if let known = preparedChannels[stream.id] { return known }
                let prepared = ProfessionalChannelMatcher.prepare(channel: stream.name,
                                                                  listings: preparedGuide(stream.epgChannelID ?? ""))
                preparedChannels[stream.id] = prepared
                return prepared
            }

            let collegeSlate = games.filter { $0.league == .ncaaf && ($0.isLive || $0.isUpcoming) }.map(Self.collegeMatchup)
            let categoryNames = currentCategories.reduce(into: [String: String]()) { $0[$1.id] = $1.matchingName.lowercased() }
            let collegeStreams = collegeSlate.isEmpty ? [] : currentStreams.filter { stream in
                let category = categoryNames[stream.categoryID ?? ""] ?? ""
                return !["radio", "radio_streams"].contains(stream.streamType?.lowercased() ?? "")
                    && !["radio", "audio", "basketball", "ncaab", "high school", "nfhs"].contains(where: { category.contains($0) })
            }
            let collegeStreamsByID = Dictionary(grouping: collegeStreams, by: \.id)
            // Each guide channel normalized once, including duplicate stream qualities.
            var collegeGuides: [String: [CollegeChannelMatcher.Listing]] = [:]
            func collegeCandidate(_ stream: XtreamStream) -> CollegeChannelMatcher.Candidate {
                let key = stream.epgChannelID ?? ""
                if collegeGuides[key] == nil { collegeGuides[key] = Self.collegeListings(guide(key)) }
                return CollegeChannelMatcher.Candidate(id: stream.id, name: stream.name, listings: collegeGuides[key] ?? [])
            }
            // The whole college pool, built the first time a game needs it.
            var collegePool: [CollegeChannelMatcher.Candidate]?
            func allCollegeCandidates() throws -> [CollegeChannelMatcher.Candidate] {
                if let collegePool { return collegePool }
                let pool = try collegeStreams.map { stream in
                    try Task.checkCancellation()
                    return collegeCandidate(stream)
                }
                collegePool = pool
                return pool
            }
            #if os(iOS)
            func carried(_ game: SportsGame) -> Set<Int>?? {
                guard let carriedShortlists, carriedShortlists.identities[game.id] == Self.matchIdentity(game) else { return nil }
                return .some(carriedShortlists.games[game.id])
            }
            // The indexes are built only when a game has no shortlist carried:
            // the first pass for a channel list and guide, or a game new to it.
            var collegeIndex: MobileSportsCandidateIndex?
            func collegeShortlist(_ game: SportsGame, _ matchup: CollegeChannelMatcher.Matchup) throws -> Set<Int>? {
                if let shortlist = carried(game) { return shortlist }
                if collegeIndex == nil {
                    let pool = try allCollegeCandidates()
                    collegeIndex = try MobileSportsCandidateIndex(channels: zip(collegeStreams, pool).map {
                        .init(id: $0.1.id, name: $0.1.normalizedName, guideID: $0.0.epgChannelID ?? "")
                    }, aliases: collegeSlate.flatMap { $0.awayAliases + $0.homeAliases }, listings: {
                        (collegeGuides[$0] ?? []).map(\.text)
                    })
                }
                return collegeIndex?.candidates(for: matchup.awayAliases + matchup.homeAliases)
            }
            var professionalIndex: MobileSportsCandidateIndex?
            func professionalShortlist(_ game: SportsGame,
                                       _ preparedGame: ProfessionalChannelMatcher.PreparedGame) throws -> Set<Int>? {
                if let shortlist = carried(game) { return shortlist }
                if professionalIndex == nil {
                    // A guide for a channel outside these pools cannot be read
                    // by a professional score. Keep all raw listings for the
                    // Guide/college.
                    let channels = try leagues.values.flatMap { $0 }.map { stream -> MobileSportsCandidateIndex.Channel in
                        try Task.checkCancellation()
                        return .init(id: stream.id, name: preparedChannel(stream).padded, guideID: stream.epgChannelID ?? "")
                    }
                    let aliases = games.filter { $0.league != .ncaaf }.flatMap { game in
                        let prepared = Self.prepared(game)
                        return prepared.away + prepared.home
                    }
                    professionalIndex = try MobileSportsCandidateIndex(channels: channels, aliases: aliases, listings: {
                        (preparedGuides[$0] ?? []).map(\.text)
                    })
                }
                return professionalIndex?.candidates(for: preparedGame.away + preparedGame.home)
            }
            var collegeScores = 0
            var professionalCandidatesScored = 0
            var collegeKept = 0
            var eventCandidates: [String: Set<Int>] = [:]
            #endif
            try Task.checkCancellation()
            // Channels in another language, settled once for the pass: an
            // English channel carrying the game comes before any of them.
            let foreign = Set(currentStreams.filter { stream in
                ChannelLanguage.isForeign(name: stream.name, category: categoryNames[stream.categoryID ?? ""] ?? "")
            }.map(\.id))
            let qualities = Dictionary(currentStreams.map { ($0.id, LiveChannelQuality(name: $0.name)) },
                                      uniquingKeysWith: { first, _ in first })
            // The tournaments with a card, for telling a channel one shares.
            let board = Self.tournamentBoard(allGames)
            let activeIDs = Set(allGames.filter { $0.isLive || $0.isUpcoming }.map(\.id))
            var matches = previousMatches.filter { activeIDs.contains($0.key) }
            var signatures = previousSignatures.filter { activeIDs.contains($0.key) }
            var evidenceByGame = previousEvidence.filter { activeIDs.contains($0.key) }
            #if os(iOS)
            var processedGames = 0
            var reportedPercent = -1
            #endif
            for game in games {
                try Task.checkCancellation()
                #if os(iOS)
                // Count completed games, including every early-continue path.
                // At most 100 main-actor updates per pass; no per-frame ticker.
                let percent = processedGames * 100 / max(1, games.count)
                if percent != reportedPercent {
                    await progress.advance(matchingWork, completed: processedGames, total: games.count)
                    reportedPercent = percent
                }
                processedGames += 1
                #endif
                // What the match, if one is kept, was made for.
                let signature = Self.matchSignature(game)
                let mayKeep = DailyCachePolicy.canReuseMatch(savedSignature: signatures[game.id],
                    currentSignature: signature, hasMatch: matches[game.id] != nil)
                // A match in another language is not kept as it stands: it is
                // looked for again, in case an English channel carries the game.
                let keptForeign = matches[game.id].map { foreign.contains($0.id) } ?? false
                if game.league == .ncaaf {
                    guard game.isLive || game.isUpcoming else { matches[game.id] = nil; continue }
                    let collegeStart = clock()
                    defer { collegeSeconds += clock() - collegeStart }
                    let matchup = Self.collegeMatchup(game)
                    #if os(iOS)
                    let possibleIDs = try collegeShortlist(game, matchup)
                    eventCandidates[game.id] = possibleIDs
                    #endif
                    // Kept the way every other league keeps its matches: a
                    // channel still showing the game is not looked past for
                    // another.
                    if mayKeep, !keptForeign, let kept = matches[game.id], collegeStreamsByID[kept.id] != nil,
                       let evidence = CollegeChannelMatcher.score(candidate: collegeCandidate(kept), game: matchup,
                                                                  now: now, allowNetworkFallback: false) {
                        #if os(iOS)
                        collegeKept += 1
                        #endif
                        evidenceByGame[game.id] = evidence
                        let diagnostic = "game=\(game.id) network=\(game.broadcast) selectedID=\(kept.id) evidence=\(evidence) policy=college-reused"
                        Logger(subsystem: "com.nulldev85.NullSports", category: "ChannelMatch").info("\(diagnostic, privacy: .public)")
                        continue
                    }
                    #if os(iOS)
                    let scoringPool = try possibleIDs.map { ids in
                        ids.sorted().flatMap { (collegeStreamsByID[$0] ?? []).map(collegeCandidate) }
                    } ?? allCollegeCandidates()
                    #else
                    let scoringPool = try allCollegeCandidates()
                    #endif
                    var best: (id: Int, score: Int)?
                    for candidate in scoringPool {
                        try Task.checkCancellation()
                        #if os(iOS)
                        collegeScores += 1
                        #endif
                        guard let score = CollegeChannelMatcher.score(candidate: candidate, game: matchup,
                            now: now, allowNetworkFallback: false) else { continue }
                        if let current = best, !Self.ranksAhead((candidate.id, score), of: current,
                            foreign: foreign, qualities: qualities) { continue }
                        best = (candidate.id, score)
                    }
                    let selected = best.flatMap { match in collegeStreamsByID[match.id]?.first }
                    matches[game.id] = selected
                    signatures[game.id] = selected == nil ? nil : signature
                    // The evidence tier that authorized the match: a wrong game names
                    // the rule that approved it without reading the matcher's source.
                    let evidence = selected.flatMap {
                        CollegeChannelMatcher.score(candidate: collegeCandidate($0), game: matchup,
                                                    now: now, allowNetworkFallback: false)
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
                #if os(iOS)
                let canIndex = [SportsLeague.nfl, .nba, .nhl, .mlb, .soccer].contains(game.league) && !game.isNFLRedZone
                let possibleIDs = try canIndex ? professionalShortlist(game, preparedGame) : nil
                eventCandidates[game.id] = possibleIDs
                #endif
                // So is a tournament's channel it shares, in case one starts
                // showing that tournament alone.
                let keptShared = game.league.isTennis && game.isEvent && (matches[game.id].map { cached in
                    Self.sharesCoverage(preparedChannel(cached), game: game, board: board, now: now)
                } ?? false)
                let reused: (stream: XtreamStream, evidence: Int)? = mayKeep && !keptForeign && !keptShared
                    ? matches[game.id].flatMap { cached in
                        Self.professionalScore(cached, game: game, preparedGame: preparedGame,
                                               channel: preparedChannel(cached),
                                               listings: guide(cached.epgChannelID ?? ""), now: now)
                            .map { (cached, $0) }
                    }
                    : nil
                var evidence = reused?.evidence
                if reused == nil {
                    var candidates = leagues[game.league] ?? []
                    #if os(iOS)
                    // These policies require team aliases in the name or guide.
                    // RedZone, racing, fights and tennis keep their full pools.
                    if let possibleIDs {
                        candidates = candidates.filter { possibleIDs.contains($0.id) }
                    }
                    professionalCandidatesScored += candidates.count
                    #endif
                    var candidateGuides: [String: [CurrentProgram]] = [:]
                    for candidate in candidates {
                        try Task.checkCancellation()
                        _ = preparedChannel(candidate)
                        let key = candidate.epgChannelID ?? ""
                        if candidateGuides[key] == nil { candidateGuides[key] = guide(key) }
                    }
                    if let stream = Self.matchedStream(for: game, candidates: candidates,
                                                       programs: candidateGuides, channels: preparedChannels,
                                                       preparedGame: preparedGame, foreign: foreign, qualities: qualities,
                                                       board: board, now: now) {
                        matches[game.id] = stream
                        signatures[game.id] = signature
                        evidence = Self.professionalScore(stream, game: game, preparedGame: preparedGame,
                                                          channel: preparedChannel(stream),
                                                          listings: guide(stream.epgChannelID ?? ""), now: now)
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
            // Prepare the Channels menu in the same background pass. Retain
            // only real matches and their evidence, not the provider's catalog.
            var preparedResults = previousPrepared.filter { activeIDs.contains($0.key) }
            for game in games {
                try Task.checkCancellation()
                var candidates = game.league == .ncaaf ? currentStreams : (leagues[game.league] ?? [])
                #if os(iOS)
                if let possible = eventCandidates[game.id] {
                    let ordinaryPool = Set(collegeStreams.map(\.id))
                    candidates = candidates.filter {
                        possible.contains($0.id) || (game.league == .ncaaf && !ordinaryPool.contains($0.id))
                    }
                }
                #endif
                let alternatives = Self.matchingEventChannels(for: game, candidates: candidates,
                    programs: listings, categories: currentCategories, board: board, now: now)
                try Task.checkCancellation()
                let selected = matches[game.id] ?? alternatives.first(where: { !$0.sharedCoverage })?.stream
                if let selected {
                    matches[game.id] = selected
                    signatures[game.id] = Self.matchSignature(game)
                    if let entry = alternatives.first(where: { $0.id == selected.id }) {
                        evidenceByGame[game.id] = entry.evidence
                    }
                }
                var evidence: [String: [CurrentProgram]] = [:]
                var groups: [String: String] = [:]
                for stream in (selected.map { [$0] } ?? []) + alternatives.map(\.stream) {
                    if let key = stream.epgChannelID { evidence[key] = listings[key] ?? [] }
                    if let key = stream.categoryID { groups[key] = categoryNames[key] ?? "" }
                }
                // Keep original category spelling: it is compared to fresh
                // category metadata, as well as fed to the strict scorer.
                for category in currentCategories where groups[category.id] != nil {
                    groups[category.id] = category.matchingName
                }
                preparedResults[game.id] = PreparedLiveMatch(preparedAt: now, eventStart: game.start,
                    identity: Self.matchIdentity(game), primary: selected, alternatives: alternatives,
                    programs: evidence, categoryNames: groups)
            }
            #if os(iOS)
            await progress.advance(matchingWork, completed: games.count, total: games.count)
            await trace.note("candidate scores", "college \(collegeScores) (\(collegeKept) kept), professional \(professionalCandidatesScored); \(preparedChannels.count) channels and \(currentGuides.count) guides read; shortlists \(professionalIndex == nil && collegeIndex == nil ? "carried" : "rebuilt"); full evidence checks retained")
            return (matches, signatures, matches != previousMatches, evidenceByGame,
                    collegeSlate.count, collegeStreams.count, collegeSeconds, professionalSeconds,
                    (eventCandidates, Set(collegeStreams.map(\.id))), preparedResults)
            #else
            return (matches, signatures, matches != previousMatches, evidenceByGame,
                    collegeSlate.count, collegeStreams.count, collegeSeconds, professionalSeconds, preparedResults)
            #endif
        }
        #if os(iOS)
        let workID = mobileSportsWork.replace(.matching, cancel: { worker.cancel() })
        defer { mobileSportsWork.finish(.matching, id: workID) }
        #endif
        guard let result = try? await trace.measure("match games to channels",
            detail: "\(games.count) games, \(leagues.values.map(\.count).reduce(0, +)) league candidates", {
                try await worker.value
            }) else {
            trace.note("matching superseded", "obsolete work stopped")
            return
        }
        trace.note("  college", "\(result.4) games over \(result.5) candidates, "
                   + String(format: "%.1fs", result.6))
        trace.note("  professional", String(format: "%.1fs", result.7))
        guard DailyCachePolicy.shouldApplyRebuild(resultGeneration: generation, currentGeneration: matchGeneration,
            resultProfileID: profileID, currentProfileID: activeProfile?.id) else { return }
        guard identities == matchIdentities(now: Date()) else { return }
        if result.2 { gameStreamCache = result.0 }
        gameMatchSignatures = result.1
        if matchEvidenceScores != result.3 { matchEvidenceScores = result.3 }
        // Every pass, changed or not: what reads it also reads the match
        // identities a pass rewrites.
        didCompleteMatching = true
        #if os(iOS)
        mobileEventCandidates = (sourceGeneration,
            Dictionary(games.map { ($0.id, Self.matchIdentity($0)) }, uniquingKeysWith: { first, _ in first }),
            result.8.0, result.8.1)
        #endif
        let newIdentities = identities.filter { result.0[$0.key] != nil }
        let identityChanged = newIdentities != matchedGameIdentities
        matchedGameIdentities = newIdentities
        #if os(iOS)
        preparedMatches = result.9
        #else
        preparedMatches = result.8
        #endif
        if dailyDue { dailyPreparedAt = now }
        eventsNeedingPreparation.subtract(games.map(\.id))
        persistPreparedMatches()
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
        guard !restoredMatchGameIDs.isEmpty else { return }
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
        #if os(iOS)
        guard canUseProviderStream(stream) else { return }
        if let source = combinedSources[stream.id] { source.library.addFavorite(source.stream) }
        #endif
        guard !isFavorite(stream) else { return }
        favoriteStreamOrder.append(stream.id)
        persistFavorites()
    }

    func removeFavorite(_ stream: XtreamStream) {
        #if os(iOS)
        guard canUseProviderStream(stream) else { return }
        if let source = combinedSources[stream.id] { source.library.removeFavorite(source.stream) }
        #endif
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
        #if os(iOS)
        if combinedRoot != nil {
            profileDefaults.set(favoriteStreamOrder, forKey: "Lineup.combinedGuide.favorites.v1")
            let contexts = Dictionary(combinedSources.values.compactMap { source in
                source.library.activeProfile.map { ($0.id, source.library) }
            }, uniquingKeysWith: { first, _ in first })
            for (id, context) in contexts {
                let native = favoriteStreamOrder.compactMap { combinedSources[$0] }
                    .filter { $0.library.activeProfile?.id == id }.map { $0.stream.id }
                let visible = Set(combinedSources.values.filter { $0.library.activeProfile?.id == id }.map { $0.stream.id })
                context.favoriteStreamOrder = native + context.favoriteStreamOrder.filter { !visible.contains($0) }
                context.persistFavorites()
            }
            return
        }
        #endif
        guard let profile = activeProfile else { return }
        profileDefaults.set(favoriteStreamOrder, forKey: favoritesKey + "." + profile.id.uuidString)
        #if os(iOS)
        if let providerOwner, providerOwner.activeProfile?.id == profile.id {
            providerOwner.favoriteStreamOrder = favoriteStreamOrder
            providerOwner.guideListCache = nil
        }
        #endif
        if profileDefaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    // MARK: - Followed teams

    /// Whose games these are. Read by the Live tab to decide what goes at the
    /// top, and by reminders to decide what is worth saying.
    private(set) var followedTeams = FollowedTeams()

    func isFollowing(_ game: SportsGame) -> Bool {
        #if os(iOS)
        // A tour follow supplements any existing individual-player follows.
        if game.league.isTennis, let tour = game.league.seriesFollow, followedTeams.contains(tour.key) { return true }
        #endif
        if let racing = game.racingFollow { return followedTeams.contains(racing.key) }
        return FollowedSlate.follows(Self.preferenceGame(game), in: followedTeams)
    }

    func isFollowing(_ key: TeamChannelKey) -> Bool { followedTeams.contains(key) }

    /// The sides of this game that can be followed, with what it takes to draw
    /// one. An event has none, which is what leaves the menu off a fight card.
    func followableSides(of game: SportsGame) -> [FollowedTeam] {
        if let racing = game.racingFollow { return [racing] }
        guard !game.isEvent else { return [] }
        let preference = Self.preferenceGame(game)
        return [(preference.awayKey, game.awayTeam, game.awayAbbreviation, game.awayLogo),
                (preference.homeKey, game.homeTeam, game.homeAbbreviation, game.homeLogo)]
            .filter { $0.0.isUsable }
            .map { FollowedTeam(key: $0.0, name: $0.1, abbreviation: $0.2, logo: $0.3) }
    }

    func toggleFollow(_ team: FollowedTeam) {
        #if os(iOS)
        if let combinedRoot { combinedRoot.toggleFollow(team); return }
        #endif
        guard activeProfile != nil else { return }
        var teams = followedTeams
        teams.toggle(team)
        followedTeams = teams
        persistFollowedTeams()
    }

    func unfollow(_ key: TeamChannelKey) {
        #if os(iOS)
        if let combinedRoot { combinedRoot.unfollow(key); return }
        #endif
        var teams = followedTeams
        teams.unfollow(key)
        followedTeams = teams
        persistFollowedTeams()
    }

    private func persistFollowedTeams() {
        guard let profile = activeProfile else { return }
        let key = followedTeamsKey + "." + profile.id.uuidString
        if let data = try? JSONEncoder().encode(followedTeams) {
            profileDefaults.set(data, forKey: key)
        }
        #if os(iOS)
        combinedGuideContext?.followedTeams = followedTeams
        for context in providerContexts.values { context.followedTeams = followedTeams }
        #endif
        if profileDefaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    private func restoreFollowedTeams() {
        guard let profile = activeProfile else {
            followedTeams = FollowedTeams()
            return
        }
        let key = followedTeamsKey + "." + profile.id.uuidString
        guard let data = profileDefaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(FollowedTeams.self, from: data) else {
            followedTeams = FollowedTeams()
            return
        }
        followedTeams = saved
    }

    // MARK: - Preferred channels by team

    /// The teams in a game, in the form the pure preference model works with.
    nonisolated private static func preferenceGame(_ game: SportsGame) -> TeamChannelGame {
        // A team's short code names it; a tennis player's surname does not --
        // there are two Zverevs and two Williamses -- so a player is kept by
        // their whole name.
        let byName = game.league.isTennis
        return TeamChannelGame(league: game.league.rawValue,
                               homeTeam: game.homeTeam, homeAbbreviation: byName ? "" : game.homeAbbreviation,
                               awayTeam: game.awayTeam, awayAbbreviation: byName ? "" : game.awayAbbreviation,
                               homeIdentity: game.league == .soccer ? game.homeTeamID.map { "ESPN:" + $0 } : nil,
                               awayIdentity: game.league == .soccer ? game.awayTeamID.map { "ESPN:" + $0 } : nil)
    }

    /// What tapping this game should do. The decision itself lives in
    /// `TeamChannelPreferences.resolve`; this only supplies the provider's
    /// current reality — which channels exist, and whether matching has settled.
    func preferredChannel(for game: SportsGame) -> PreferredChannel {
        // A manual choice for this exact event is the strongest possible
        // evidence of intent. Unlike a team preference it does not need guide
        // verification: the viewer just confirmed the feed while watching the
        // game, and providers commonly leave those ad-hoc channels without EPG.
        if let saved = gameChannelSelections.selection(for: game.id),
           let stream = stream(withID: saved.streamID), stream.name == saved.channelName {
            return .play(streamID: saved.streamID, source: .gameSelection)
        }
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
                                       matchingReady: eventChannelsReady(for: game) || !channelsAreSyncing,
                                       availableStreamIDs: Set(streams.map(\.id)),
                                       verifiedStreamIDs: verified,
                                       verifiedStreamID: verifiedStream(for: game)?.id)
    }

    func stream(withID id: Int) -> XtreamStream? {
        streamIndex[id]
    }

    /// Each channel by its id, built the first time one is asked for after
    /// the list changes. A provider can have tens of thousands of channels,
    /// and finding one used to mean reading through all of them -- on the
    /// main thread, while screens drew.
    @ObservationIgnored private var streamIndexCache: [Int: XtreamStream]?
    private var streamIndex: [Int: XtreamStream] {
        if let streamIndexCache { return streamIndexCache }
        let built = Dictionary(streams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        streamIndexCache = built
        return built
    }

    /// Which sides of this game a preference can be saved for, home first.
    func preferenceSides(for game: SportsGame) -> [TeamChannelSide] {
        let teams = Self.preferenceGame(game)
        return [TeamChannelSide(key: teams.homeKey, team: game.homeTeam, isHome: true),
                TeamChannelSide(key: teams.awayKey, team: game.awayTeam, isHome: false)]
            .filter { $0.key.isUsable }
    }

    func savePreference(_ stream: XtreamStream, for key: TeamChannelKey, teamName: String) {
        #if os(iOS)
        guard canUseProviderStream(stream) else { return }
        if let source = combinedSources[stream.id] { source.library.savePreference(source.stream, for: key, teamName: teamName) }
        #endif
        teamPreferences.set(TeamChannelPreference(streamID: stream.id, channelName: stream.name,
                                                  teamName: teamName), for: key)
        persistTeamPreferences()
    }

    /// Remember a manual channel only for this scheduled game. Every scope in
    /// the iPhone choice sheet records this exact-game selection; the team
    /// choices additionally call `savePreference` for future games.
    func saveGameSelection(_ stream: XtreamStream, for game: SportsGame) {
        #if os(iOS)
        guard canUseProviderStream(stream) else { return }
        if let source = combinedSources[stream.id] { source.library.saveGameSelection(source.stream, for: game) }
        #endif
        gameChannelSelections.prune()
        gameChannelSelections.set(GameChannelSelection(streamID: stream.id,
                                                        channelName: stream.name,
                                                        gameStart: game.start),
                                  for: game.id)
        persistGameChannelSelections()
    }

    func removePreference(for key: TeamChannelKey) {
        #if os(iOS)
        if combinedRoot != nil {
            for context in combinedProviderContexts.values { context.removePreference(for: key) }
        }
        #endif
        teamPreferences.remove(for: key)
        persistTeamPreferences()
        #if os(iOS)
        syncProviderPreferenceRemoval(key: key, all: false)
        #endif
    }

    func removeAllPreferences() {
        #if os(iOS)
        if combinedRoot != nil {
            for context in combinedProviderContexts.values { context.removeAllPreferences() }
        }
        #endif
        teamPreferences.removeAll()
        gameChannelSelections.removeAll()
        persistTeamPreferences()
        persistGameChannelSelections()
        #if os(iOS)
        syncProviderPreferenceRemoval(key: nil, all: true)
        #endif
    }

    #if os(iOS)
    /// Settings still edits the preferred account. Retire its displayed
    /// overrides too, so a removed preference cannot reappear on the next load.
    private func syncProviderPreferenceRemoval(key: TeamChannelKey?, all: Bool) {
        guard combinedRoot == nil, providerOwner == nil, let id = activeProfile?.id else { return }
        providerContexts[id]?.teamPreferences = teamPreferences
        providerContexts[id]?.gameChannelSelections = gameChannelSelections
        guard let guide = combinedGuideContext else { return }
        guide.teamPreferences = TeamChannelPreferences(entries: guide.teamPreferences.entries.filter { entry in
            let owned = guide.combinedSources[entry.value.streamID]?.library.activeProfile?.id == id
            return !owned || (!all && entry.key != key?.storageKey)
        })
        if all {
            guide.gameChannelSelections = GameChannelSelections(entries: guide.gameChannelSelections.entries.filter {
                guide.combinedSources[$0.value.streamID]?.library.activeProfile?.id != id
            })
            guide.persistGameChannelSelections()
        }
        guide.persistTeamPreferences()
    }
    #endif

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
        #if os(iOS)
        guard canUseProviderStream(stream) else { return }
        if let source = combinedSources[stream.id] { source.library.recordRecentChannel(source.stream) }
        #endif
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
        // In the order they were watched, leaving out any the provider no
        // longer has.
        recentStreamOrder.compactMap { streamIndex[$0] }
    }

    func clearRecentChannels() {
        #if os(iOS)
        if combinedRoot != nil {
            for context in combinedProviderContexts.values { context.clearRecentChannels() }
        } else if providerOwner == nil, let id = activeProfile?.id {
            providerContexts[id]?.recentStreamOrder = []
            if let guide = combinedGuideContext {
                guide.recentStreamOrder.removeAll { guide.combinedSources[$0]?.library.activeProfile?.id == id }
                guide.guideListCache = nil
                guide.persistRecentChannels()
            }
        }
        #endif
        guard !recentStreamOrder.isEmpty else { return }
        recentStreamOrder = []
        guideListCache = nil
        persistRecentChannels()
    }

    private func persistRecentChannels() {
        #if os(iOS)
        if combinedRoot != nil {
            profileDefaults.set(recentStreamOrder, forKey: "Lineup.combinedGuide.recents.v1")
            return
        }
        #endif
        guard let profile = activeProfile else { return }
        profileDefaults.set(recentStreamOrder, forKey: recentsKey + "." + profile.id.uuidString)
        #if os(iOS)
        if let providerOwner, providerOwner.activeProfile?.id == profile.id { providerOwner.recentStreamOrder = recentStreamOrder }
        #endif
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
        let preparedGame = Self.prepared(game)
        let categoryNames = Dictionary(categories.map { ($0.categoryID, $0.matchingName) },
                                       uniquingKeysWith: { first, _ in first })
        let foreign = Set(streams(for: game.league).filter { stream in
            ChannelLanguage.isForeign(name: stream.name, category: categoryNames[stream.categoryID ?? ""] ?? "")
        }.map(\.id))
        let qualities = Dictionary(streams(for: game.league).map { ($0.id, LiveChannelQuality(name: $0.name)) },
                                  uniquingKeysWith: { first, _ in first })
        let board = game.league.isTennis && game.isEvent
            ? Self.tournamentBoard(SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }) : []
        var shared: Set<Int> = []
        let scored = streams(for: game.league)
            .filter { $0.id != verified?.id && $0.id != preferred?.streamID }
            .compactMap { stream -> (stream: XtreamStream, score: Int)? in
                let programs = stream.epgChannelID.flatMap { listings[$0] } ?? []
                let preparedListings = ProfessionalChannelMatcher.prepare(programs.map {
                    .init(title: $0.title, detail: $0.detail, start: $0.start, end: $0.end)
                })
                let channel = ProfessionalChannelMatcher.prepare(channel: stream.name,
                                                                  listings: preparedListings)
                guard let score = Self.professionalScore(stream, game: game, preparedGame: preparedGame,
                                                         channel: channel, listings: programs, now: now) else { return nil }
                if Self.sharesCoverage(channel, game: game, board: board, now: now) { shared.insert(stream.id) }
                return (stream, score)
            }
        let alternates = scored
            .sorted { Self.ranksAhead(($0.stream.id, $0.score), of: ($1.stream.id, $1.score), foreign: foreign,
                                      qualities: qualities, shared: shared) }
            .prefix(limit)
            .map { FailoverChannel(streamID: $0.stream.id, name: $0.stream.name, reason: .alternate) }
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
        #if os(iOS)
        if combinedRoot != nil {
            profileDefaults.set(try? JSONEncoder().encode(teamPreferences), forKey: "Lineup.combinedGuide.teamPreferences.v1")
            return
        }
        #endif
        // Strictly per provider, and never merged across them the way favorites
        // are: a channel identifier only means something inside the provider
        // that issued it.
        guard let profile = activeProfile,
              let data = try? JSONEncoder().encode(teamPreferences) else { return }
        profileDefaults.set(data, forKey: teamPreferencesKey + "." + profile.id.uuidString)
        #if os(iOS)
        if let providerOwner, providerOwner.activeProfile?.id == profile.id { providerOwner.teamPreferences = teamPreferences }
        #endif
        if profileDefaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
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

    private func persistGameChannelSelections() {
        #if os(iOS)
        if combinedRoot != nil {
            profileDefaults.set(try? JSONEncoder().encode(gameChannelSelections), forKey: "Lineup.combinedGuide.gameSelections.v1")
            return
        }
        #endif
        guard let profile = activeProfile,
              let data = try? JSONEncoder().encode(gameChannelSelections) else { return }
        profileDefaults.set(data, forKey: gameChannelSelectionsKey + "." + profile.id.uuidString)
        #if os(iOS)
        if let providerOwner, providerOwner.activeProfile?.id == profile.id { providerOwner.gameChannelSelections = gameChannelSelections }
        #endif
        if profileDefaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    private func restoreGameChannelSelections() {
        guard let profile = activeProfile,
              let data = profileDefaults.data(forKey: gameChannelSelectionsKey + "." + profile.id.uuidString),
              var saved = try? JSONDecoder().decode(GameChannelSelections.self, from: data) else {
            gameChannelSelections = GameChannelSelections()
            return
        }
        let unpruned = saved
        saved.prune()
        gameChannelSelections = saved
        // Put the pruned value back so finished games do not collect forever.
        if saved != unpruned { persistGameChannelSelections() }
    }

    /// A tournament's card on a channel it shares, as a picture of it is
    /// labeled -- see `sharedCoverageTitle(channel:listings:game:board:now:)`.
    func sharedCoverageTitle(for game: SportsGame, on stream: XtreamStream, now: Date = Date()) -> String? {
        guard game.league.isTennis, game.isEvent else { return nil }
        return Self.sharedCoverageTitle(channel: stream.name, listings: programs(for: stream), game: game,
            board: Self.tournamentBoard(SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] }), now: now)
    }

    private func programs(for stream: XtreamStream) -> [CurrentProgram] {
        guard let channelID = stream.epgChannelID else { return [] }
        return programsByChannel[channelID] ?? []
    }

    func playbackURLs(for stream: XtreamStream) -> [URL] {
        #if os(iOS)
        guard providerConnectionAvailable else { return [] }
        if let source = combinedSources[stream.id] {
            guard source.library.activeProfile.map({ combinedRoot?.isProviderEnabled($0.id) == true }) == true else { return [] }
            return source.library.playbackURLs(for: source.stream)
        }
        if combinedRoot != nil { return [] }
        #endif
        let urls = sourcePlaybackURLs(for: stream)
        if let profile = activeProfile,
           let preferred = measuredPlaybackURLs["\(profile.id.uuidString)|\(stream.id)"],
           preferred.expires > Date(), urls.contains(preferred.url) {
            return [preferred.url] + urls.filter { $0 != preferred.url }
        }
        return urls
    }

    private func sourcePlaybackURLs(for stream: XtreamStream) -> [URL] {
        #if os(iOS)
        guard providerConnectionAvailable else { return [] }
        if let source = combinedSources[stream.id] { return source.library.sourcePlaybackURLs(for: source.stream) }
        if combinedRoot != nil { return [] }
        #endif
        guard let profile = activeProfile, let password = password(for: profile) else { return [] }
        if profile.isPlaylist, let url = preparedPlaylistURLs[stream.id] { return [url] }
        return XtreamClient(profile: profile, password: password).playbackURLs(for: stream)
    }

    // MARK: - Catch-up

    /// On-demand NFL replay browsing, scoped to the account that requested it.
    /// The regular Guide keeps its existing, more permissive catch-up behavior.
    func gameReplayProgrammes(for stream: XtreamStream, profileID: UUID) async throws -> [CatchUpProgramme] {
        #if os(iOS)
        guard providerConnectionAvailable else { throw CancellationError() }
        if let source = combinedSources[stream.id], let id = source.library.activeProfile?.id {
            return try await source.library.gameReplayProgrammes(for: source.stream, profileID: id).map {
                CatchUpProgramme(streamID: stream.id, title: $0.title, detail: $0.detail, start: $0.start, end: $0.end)
            }
        }
        if combinedRoot != nil { throw XtreamClient.XtreamError.invalidResponse }
        #endif
        guard let profile = activeProfile, profile.id == profileID, !profile.isPlaylist,
              stream.hasCatchUp, let secret = password(for: profile) else { throw XtreamClient.XtreamError.invalidResponse }
        let table = try await XtreamClient(profile: profile, password: secret).catchUpTable(streamID: stream.id)
        guard !Task.isCancelled, activeProfile?.id == profileID else { throw CancellationError() }
        return table.confirmedGameRecordings(for: stream)
    }

    /// The server's time zone for the active provider, found once a session.
    @ObservationIgnored private var catchUpZoneCache: (profileID: UUID, zone: TimeZone)?

    /// The server's time zone, which catch-up addresses are written in: as
    /// the account's own details state it, else as a channel's catch-up
    /// table shows it, else UTC, which is what most panels keep. Only a zone
    /// the server gave is kept; a guess is tried again next time.
    func catchUpTimeZone(for stream: XtreamStream? = nil) async -> TimeZone {
        #if os(iOS)
        guard providerConnectionAvailable else { return TimeZone(secondsFromGMT: 0) ?? .current }
        if let stream, let source = combinedSources[stream.id] {
            return await source.library.catchUpTimeZone(for: source.stream)
        }
        #endif
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        guard let profile = activeProfile, let password = password(for: profile) else { return utc }
        if let catchUpZoneCache, catchUpZoneCache.profileID == profile.id { return catchUpZoneCache.zone }
        let client = XtreamClient(profile: profile, password: password)
        var zone = try? await client.authenticate().serverInfo?.timeZone
        if zone == nil, let stream {
            zone = try? await client.catchUpTable(streamID: stream.streamID).serverTimeZone
        }
        guard let zone else { return utc }
        if activeProfile?.id == profile.id { catchUpZoneCache = (profile.id, zone) }
        return zone
    }

    /// Where a channel's recording plays from, from `start` until `end`, in
    /// the order the playback engines try addresses in (the same order as
    /// `playbackURLs`: the one to try first is first).
    func catchUpURLs(for stream: XtreamStream, from start: Date, until end: Date,
                     in zone: TimeZone) -> [URL] {
        #if os(iOS)
        guard providerConnectionAvailable else { return [] }
        if let source = combinedSources[stream.id] {
            return source.library.catchUpURLs(for: source.stream, from: start, until: end, in: zone)
        }
        if combinedRoot != nil { return [] }
        #endif
        guard let profile = activeProfile, let password = password(for: profile) else { return [] }
        let begin = CatchUpPolicy.minute(start)
        return XtreamClient(profile: profile, password: password).catchUpURLs(
            for: stream, from: begin, minutes: CatchUpPolicy.minutes(from: begin, to: end),
            serverTimeZone: zone)
    }

    /// How to play a channel's recording, once the server's time zone is
    /// known. Nil for a channel the provider doesn't record.
    func catchUpSource(for stream: XtreamStream) async -> CatchUpSource? {
        guard stream.hasCatchUp else { return nil }
        #if os(iOS)
        guard !playbackURLs(for: stream).isEmpty else { return nil }
        #endif
        let zone = await catchUpTimeZone(for: stream)
        let programmes = guidePrograms(for: stream).normalizedEPG()
        return CatchUpSource(
            stream: stream,
            liveURLs: playbackURLs(for: stream),
            addresses: catchUpAddresses(for: stream, in: zone),
            programme: { time in programmes.first { $0.start <= time && time < $0.end } })
    }

    /// The recording's addresses from any start until any end, for a player
    /// to call as it moves through the recording. The account is read once,
    /// here, so the player can ask as often as it needs to.
    func catchUpAddresses(for stream: XtreamStream, in zone: TimeZone) -> (Date, Date) -> [URL] {
        #if os(iOS)
        if let source = combinedSources[stream.id] {
            return source.library.catchUpAddresses(for: source.stream, in: zone)
        }
        if combinedRoot != nil { return { _, _ in [] } }
        #endif
        guard let profile = activeProfile, let password = password(for: profile) else { return { _, _ in [] } }
        let client = XtreamClient(profile: profile, password: password)
        return { start, end in
            #if os(iOS)
            guard self.providerConnectionAvailable else { return [] }
            #endif
            let begin = CatchUpPolicy.minute(start)
            return client.catchUpURLs(for: stream, from: begin,
                                      minutes: CatchUpPolicy.minutes(from: begin, to: end),
                                      serverTimeZone: zone)
        }
    }

    /// What a channel showed that the provider kept, newest first, as far
    /// back as it keeps it. A panel that marks no listing as kept, though the
    /// channel says it records, is taken at the channel's word.
    func catchUpProgrammes(for stream: XtreamStream) async throws -> [CatchUpProgramme] {
        #if os(iOS)
        guard providerConnectionAvailable else { return [] }
        if let source = combinedSources[stream.id] {
            let native = try await source.library.catchUpProgrammes(for: source.stream)
            return native.map { CatchUpProgramme(streamID: stream.id, title: $0.title, detail: $0.detail, start: $0.start, end: $0.end) }
        }
        if combinedRoot != nil { return [] }
        #endif
        guard let profile = activeProfile, let password = password(for: profile) else { return [] }
        let table = try await XtreamClient(profile: profile, password: password)
            .catchUpTable(streamID: stream.streamID)
        let now = Date()
        let oldest = now.addingTimeInterval(-Double(max(1, stream.archiveDays)) * 86_400)
        let past = table.listings.filter { $0.start < now && $0.end > oldest }
        let kept = past.contains(where: \.hasArchive) ? past.filter(\.hasArchive) : past
        var seen = Set<Date>()
        return kept
            .filter { seen.insert($0.start).inserted }
            .map { CatchUpProgramme(streamID: stream.streamID, title: $0.title, detail: $0.detail,
                                    start: $0.start, end: $0.end) }
            .sorted { $0.start > $1.start }
    }

    /// The provider's password, read from the keychain once rather than on
    /// every call. Stream addresses are built while screens draw -- the Live
    /// tab's preview builds one on every redraw -- and each keychain read is
    /// a round trip to another process on the main thread.
    @ObservationIgnored private var passwordCache: (profileID: UUID, password: String)?

    private func password(for profile: XtreamProfile) -> String? {
        if let passwordCache, passwordCache.profileID == profile.id { return passwordCache.password }
        guard let password = credentials.password(profile.id) else { return nil }
        passwordCache = (profile.id, password)
        return password
    }

    private func restoreFavorites() {
        restoreFollowedTeams()
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
        activeProfile = profiles.first { $0.id == profile.id } ?? profile
        restoreFavorites()
        restoreTeamPreferences()
        restoreGameChannelSelections()
        restoreRecentChannels()
        persistProfiles()
        isSwitchingProfile = false
        await bootstrap()
    }

    /// Change only the display name. Identity, credentials and every provider's
    /// favorites, channel preferences, caches and selected Guide category stay put.
    @discardableResult
    func renameProfile(id: UUID, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].name = trimmed
        if activeProfile?.id == id { activeProfile = profiles[index] }
        persistProfiles()
        return true
    }

    var enabledProfiles: [XtreamProfile] { profiles.filter { !disabledProviderIDs.contains($0.id) } }

    func isProviderEnabled(_ id: UUID) -> Bool {
        profiles.contains { $0.id == id } && !disabledProviderIDs.contains(id)
    }

    func setProviderEnabled(_ id: UUID, enabled: Bool) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        if enabled { disabledProviderIDs.remove(id) } else { disabledProviderIDs.insert(id) }
        profileDefaults.set(disabledProviderIDs.map(\.uuidString), forKey: "Lineup.disabledIPTVProviders.v1")
        #if os(iOS)
        if !enabled { providerContexts[id] = nil }
        #endif
    }

    #if os(iOS)
    var eventChannelTournamentBoard: [[String]] {
        Self.tournamentBoard(SportsLeague.allCases.flatMap { gamesByLeague[$0] ?? [] })
    }

    /// Each enabled account owns a separate store. Resolving a feed never
    /// switches the preferred account or retires another provider's playback.
    func providerContext(id: UUID, catalog: MobileProviderCatalog = .shared) async -> SportsLibrary? {
        if let combinedRoot { return await combinedRoot.providerContext(id: id, catalog: catalog) }
        if activeProfile?.id == id && !preparedMatches.isEmpty {
            providerContextLoads[id]?.cancel()
            providerContextLoads[id] = nil
            return await buildProviderContext(id: id, catalog: catalog)
        }
        if let pending = providerContextLoads[id] { return await pending.value }
        let pending = Task { await self.buildProviderContext(id: id, catalog: catalog) }
        providerContextLoads[id] = pending
        defer { providerContextLoads[id] = nil }
        return await pending.value
    }

    private func buildProviderContext(id: UUID, catalog: MobileProviderCatalog) async -> SportsLibrary? {
        guard isProviderEnabled(id), let profile = profiles.first(where: { $0.id == id }) else { return nil }
        guard let secret = credentials.password(id) else {
            providerProblems[id] = "Sign in again in Settings → IPTV"
            return nil
        }
        let context: SportsLibrary
        if let existing = providerContexts[id], let saved = existing.activeProfile,
           Self.sameProviderConnection(saved, profile) {
            context = existing
        } else {
            context = SportsLibrary(profileDefaults: profileDefaults, credentials: credentials,
                providerID: id, persistsActiveSelection: false, preparedCacheDirectory: preparedCacheDirectory,
                automaticRefreshes: automaticRefreshes, providerSession: providerSession,
                scheduleCacheLocation: scheduleCacheLocation)
            providerContexts[id] = context
        }
        context.providerOwner = self
        // The primary uses the root's prepared proof. Other accounts restore
        // their own proof before asking their catalog for anything.
        if context.preparedMatches.isEmpty, preparedMatches.isEmpty || activeProfile?.id != id {
            _ = await context.restorePreparedMatches()
        }
        // Wait only for local cache installation, never for network refreshes.
        // Starting a second catalog request here used to keep the primary
        // provider hidden after its cached match was already playable.
        if activeProfile?.id == id, preparedMatches.isEmpty, cachedRestoreInFlight {
            await waitForCachedRestore()
            guard !Task.isCancelled, isProviderEnabled(id),
                  profiles.contains(where: { Self.sameProviderConnection($0, profile) }) else { return nil }
        }
        let usesPrimary = activeProfile?.id == id
            && (automaticMatchingReady || !preparedMatches.isEmpty || (channelsAreSyncing && !streams.isEmpty))
        let usesPrepared = !usesPrimary && !context.preparedMatches.isEmpty
        let snapshot: MobileProviderSnapshot
        if usesPrimary {
            snapshot = MobileProviderSnapshot(categories: categories, streams: streams, programs: programsByChannel,
                fetchedAt: min(libraryUpdatedAt ?? Date(), guideUpdatedAt ?? Date()))
        } else if usesPrepared {
            snapshot = MobileProviderSnapshot(categories: context.categories, streams: context.streams,
                programs: context.programsByChannel, fetchedAt: context.libraryUpdatedAt ?? .distantPast)
        } else {
            do { snapshot = try await catalog.snapshot(for: profile, secret: secret) }
            catch {
                // Say why: a guide that will not read and a server that is
                // down call for different things from the person reading it.
                providerProblems[id] = "Channels or guide unavailable: \(error.localizedDescription)"
                return nil
            }
        }
        guard !Task.isCancelled, isProviderEnabled(id), credentials.password(id) == secret,
              let current = profiles.first(where: { $0.id == id }),
              Self.sameProviderConnection(current, profile) else { return nil }
        context.profiles = profiles
        context.providerOwner = self
        context.activeProfile = current
        context.disabledProviderIDs = disabledProviderIDs
        context.followedTeams = followedTeams
        if !gamesByLeague.isEmpty, context.gamesByLeague.isEmpty
            || (scheduleSnapshotAt ?? .distantPast) >= (context.scheduleSnapshotAt ?? .distantPast) {
            if context.gamesByLeague != gamesByLeague { context.gamesByLeague = gamesByLeague }
            context.scheduleLoadedLeagues = scheduleLoadedLeagues
            context.scheduleSnapshotAt = scheduleSnapshotAt
            context.scheduleDay = scheduleDay
            context.scheduleValidatedLeagues = scheduleValidatedLeagues
        }
        context.didRestoreSchedule = true
        context.channelsValidatedThisSession = usesPrimary ? channelsValidatedThisSession : (!usesPrepared || context.channelsValidatedThisSession)
        context.guideValidatedThisSession = usesPrimary ? guideValidatedThisSession : (!usesPrepared || context.guideValidatedThisSession)
        let changed = usesPrimary
            ? context.mirroredStreamsRevision != streamsRevision || context.mirroredGuideRevision != guideRevision
            : context.libraryUpdatedAt != snapshot.fetchedAt
        if changed && !usesPrepared {
            context.categories = snapshot.categories
            context.streams = snapshot.streams
            context.programsByChannel = snapshot.programs
            context.libraryUpdatedAt = snapshot.fetchedAt
            context.guideUpdatedAt = snapshot.fetchedAt
            context.categoriesDigest = nil; context.streamsDigest = nil; context.guideDigest = nil
            context.savedChannelsDigest = nil; context.savedGuideDigest = nil
            context.passwordCache = nil
        }
        if usesPrimary {
            context.mirroredStreamsRevision = streamsRevision
            context.mirroredGuideRevision = guideRevision
            if context.mirroredPreparedRevision != preparedMatchesRevision {
                context.preparedMatches = preparedMatches
                context.mirroredPreparedRevision = preparedMatchesRevision
            }
            context.dailyPreparedAt = dailyPreparedAt
            context.hasFullCatalog = hasFullCatalog
            context.hasFullGuide = hasFullGuide
            context.preparedPlaylistURLs = preparedPlaylistURLs
            context.indexGeneration = indexGeneration
            context.professionalStreams = professionalStreams
            context.leagueStreamCache = leagueStreamCache
            context.sportsIndexReady = sportsIndexReady
            context.didCompleteMatching = didCompleteMatching
            context.gameStreamCache = gameStreamCache
            context.matchedGameIdentities = matchedGameIdentities
            context.fastValidatedGameIDs = fastValidatedGameIDs
        } else if usesPrepared {
            if automaticRefreshes, !context.didRestoreProviderCache, providerBootstraps[id] == nil {
                providerBootstraps[id] = Task { [weak self, weak context] in
                    await context?.bootstrap()
                    guard let self else { return }
                    self.providerBootstraps[id] = nil
                    self.providerContextsRevision &+= 1
                }
            } else { context.refreshProviderIfNeeded() }
        } else if changed {
            context.hasFullCatalog = true
            context.hasFullGuide = true
            await context.rebuildProfessionalStreams()
        } else { await context.rebuildGameStreamCache() }
        guard !Task.isCancelled, isProviderEnabled(id),
              let saved = profiles.first(where: { $0.id == id }),
              Self.sameProviderConnection(saved, current), credentials.password(id) == secret else { return nil }
        providerProblems[id] = nil
        return context
    }

    func prepareEventChannel(_ choice: MobileProviderChannel, for game: SportsGame,
                             catalog: MobileProviderCatalog = .shared) async -> MobileProviderPlaybackSource? {
        if let combinedRoot { return await combinedRoot.prepareEventChannel(choice, for: game, catalog: catalog) }
        guard let profile = profiles.first(where: { $0.id == choice.profile.id }),
              Self.sameProviderConnection(profile, choice.profile),
              let context = await providerContext(id: profile.id, catalog: catalog) else { return nil }
        let current = gamesByLeague[game.league]?.first { $0.id == game.id } ?? game
        guard current.isLive || current.isUpcoming,
              let stream = context.stream(withID: choice.channel.id), stream == choice.channel.stream,
              context.isEventChannel(stream, verifiedFor: current) else { return nil }
        return MobileProviderPlaybackSource(library: context, stream: stream)
    }

    func providerSnapshot(_ profile: XtreamProfile, catalog: MobileProviderCatalog = .shared) async throws -> MobileProviderSnapshot {
        if let combinedRoot { return try await combinedRoot.providerSnapshot(profile, catalog: catalog) }
        guard isProviderEnabled(profile.id), let current = profiles.first(where: { $0.id == profile.id }),
              Self.sameProviderConnection(current, profile), let secret = credentials.password(profile.id) else {
            throw XtreamClient.XtreamError.unauthorized
        }
        let snapshot = try await catalog.snapshot(for: current, secret: secret)
        guard !Task.isCancelled, isProviderEnabled(current.id), credentials.password(current.id) == secret,
              profiles.contains(where: { Self.sameProviderConnection($0, current) }) else { throw CancellationError() }
        return snapshot
    }

    func playbackSource(for stream: XtreamStream) -> MobileProviderPlaybackSource {
        combinedSources[stream.id] ?? MobileProviderPlaybackSource(library: self, stream: stream)
    }

    var providerRoot: SportsLibrary { combinedRoot ?? providerOwner ?? self }

    private var providerConnectionAvailable: Bool {
        guard let providerOwner else { return true }
        guard let profile = activeProfile else { return false }
        return providerOwner.isProviderEnabled(profile.id)
            && providerOwner.profiles.contains { Self.sameProviderConnection($0, profile) }
    }

    private func canUseProviderStream(_ stream: XtreamStream) -> Bool {
        providerConnectionAvailable && (combinedRoot == nil
            || combinedSources[stream.id].map { $0.library.providerConnectionAvailable } == true)
    }

    func displayStream(for source: MobileProviderPlaybackSource) -> XtreamStream? {
        guard let id = source.library.activeProfile?.id,
              let displayed = combinedDisplayIDs[.init(providerID: id, streamID: source.stream.id)] else { return nil }
        return stream(withID: displayed)
    }

    var searchGamesSnapshot: [(game: SportsGame, channel: XtreamStream?)] {
        games(for: nil).flatMap { game -> [(game: SportsGame, channel: XtreamStream?)] in
            if combinedRoot != nil {
                let matched = enabledProfiles.compactMap { profile -> XtreamStream? in
                    guard let context = combinedProviderContexts[profile.id], let native = context.resolvedStream(for: game) else { return nil }
                    return displayStream(for: MobileProviderPlaybackSource(library: context, stream: native))
                }
                return matched.isEmpty ? [(game, nil)] : matched.map { (game, Optional($0)) }
            }
            return [(game, resolvedStream(for: game))]
        }
    }

    var searchProviderInfo: [Int: XtreamProfile] {
        Dictionary(streams.compactMap { stream in
            playbackSource(for: stream).library.activeProfile.map { (stream.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    func categorySource(for id: String) -> (profileID: UUID?, categoryID: String) {
        if combinedRoot != nil, let split = id.firstIndex(of: "|"),
           let profileID = UUID(uuidString: String(id[..<split])) {
            return (profileID, String(id[id.index(after: split)...]))
        }
        return (activeProfile?.id, id)
    }

    func providerName(for stream: XtreamStream) -> String? {
        if combinedRoot != nil && combinedSources[stream.id] == nil { return nil }
        let source = playbackSource(for: stream)
        let id = source.library.activeProfile?.id
        return providerRoot.profiles.first { $0.id == id }?.name
    }

    func combinedGuide(catalog: MobileProviderCatalog = .shared,
                       onUpdate: @MainActor (SportsLibrary) -> Void = { _ in }) async -> SportsLibrary {
        if let combinedRoot { return await combinedRoot.combinedGuide(catalog: catalog, onUpdate: onUpdate) }
        let facade = combinedGuideContext ?? SportsLibrary(profileDefaults: profileDefaults,
            credentials: credentials, persistsActiveSelection: false)
        combinedGuideContext = facade
        combinedLoadCount += 1
        facade.isLoading = true
        defer { combinedLoadCount -= 1; facade.isLoading = combinedLoadCount > 0 }
        facade.combinedRoot = self
        if combinedRegistry == nil { combinedRegistry = MobileProviderStreamRegistry(defaults: profileDefaults) }
        let ids = enabledProfiles.map(\.id)
        var loaded = providerContexts.filter { isProviderEnabled($0.key) }
        installCombinedGuide(facade, contexts: loaded)
        onUpdate(facade)
        await withTaskGroup(of: (UUID, SportsLibrary?).self) { group in
            for id in ids { group.addTask { (id, await self.providerContext(id: id, catalog: catalog)) } }
            while let (id, context) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let context, isProviderEnabled(id) { loaded[id] = context }
                else if let existing = loaded[id], isProviderEnabled(id), existing.providerConnectionAvailable {
                    // Keep an already-playing channel during metadata refresh/
                    // failure, but retire its automatic event evidence.
                    existing.channelsValidatedThisSession = false
                    existing.guideValidatedThisSession = false
                    existing.fastValidatedGameIDs = []
                } else { loaded[id] = nil }
                installCombinedGuide(facade, contexts: loaded)
                onUpdate(facade)
            }
        }
        if !Task.isCancelled { installCombinedGuide(facade, contexts: loaded) }
        return facade
    }

    private func installCombinedGuide(_ facade: SportsLibrary, contexts: [UUID: SportsLibrary]) {
        guard let registry = combinedRegistry else { return }
        let ordered = enabledProfiles.compactMap { contexts[$0.id] }
        facade.profiles = profiles
        facade.activeProfile = activeProfile
        facade.disabledProviderIDs = disabledProviderIDs
        facade.libraryUpdatedAt = ordered.compactMap(\.libraryUpdatedAt).min()
        facade.guideUpdatedAt = ordered.compactMap(\.guideUpdatedAt).min()
        // A provider may restore its compact snapshot before the root finishes
        // its own disk work. Publish that schedule instead of an empty facade.
        let scheduleSource = ([self] + ordered).filter { !$0.gamesByLeague.isEmpty }
            .max { ($0.scheduleSnapshotAt ?? .distantPast) < ($1.scheduleSnapshotAt ?? .distantPast) } ?? self
        if facade.gamesByLeague != scheduleSource.gamesByLeague { facade.gamesByLeague = scheduleSource.gamesByLeague }
        facade.scheduleLoadedLeagues = scheduleSource.scheduleLoadedLeagues
        facade.scheduleValidatedLeagues = scheduleSource.scheduleValidatedLeagues
        facade.scheduleSnapshotAt = scheduleSource.scheduleSnapshotAt
        facade.isScheduleLoading = isScheduleLoading
        facade.scheduleErrorMessage = scheduleErrorMessage
        facade.followedTeams = followedTeams
        let signature = ordered.map { "\($0.activeProfile!.id)|\($0.activeProfile!.name)|\($0.libraryUpdatedAt?.timeIntervalSince1970 ?? 0)|\($0.guideUpdatedAt?.timeIntervalSince1970 ?? 0)|\($0.indexGeneration)|\($0.automaticMatchingReady)|\($0.preparedMatchesRevision)" }
        guard facade.combinedSignature != signature else {
            facade.restoreCombinedOrders()
            facade.refreshCombinedMatches(contexts: ordered, registry: registry)
            return
        }
        facade.combinedSignature = signature
        var channels: [XtreamStream] = [], groups: [XtreamCategory] = []
        var guide: [String: [CurrentProgram]] = [:]
        var sources: [Int: MobileProviderPlaybackSource] = [:]
        var displayIDs: [MobileProviderChannel.ID: Int] = [:]
        var professional: [XtreamStream] = []
        var leagues: [SportsLeague: [XtreamStream]] = [:]
        for context in ordered {
            guard let profile = context.activeProfile else { continue }
            let prefix = profile.id.uuidString + "|"
            var displayed: [Int: XtreamStream] = [:]
            groups += context.categories.map { XtreamCategory(categoryID: prefix + $0.id,
                categoryName: "\(profile.name) · \($0.categoryName)", sourceCategoryName: $0.matchingName) }
            for native in context.streams {
                let id = registry.id(provider: profile.id, stream: native.id)
                let channel = XtreamStream(num: native.num, name: native.name, streamType: native.streamType,
                    streamID: id, streamIcon: native.streamIcon,
                    epgChannelID: native.epgChannelID.map { prefix + $0 }, categoryID: native.categoryID.map { prefix + $0 },
                    tvArchive: native.tvArchive, archiveDays: native.archiveDays)
                channels.append(channel)
                displayed[native.id] = channel
                sources[id] = MobileProviderPlaybackSource(library: context, stream: native)
                displayIDs[.init(providerID: profile.id, streamID: native.id)] = id
            }
            for (id, listings) in context.programsByChannel { guide[prefix + id] = listings }
            if context.sportsIndexReady {
                professional += context.professionalStreams.compactMap { displayed[$0.id] }
                for (league, values) in context.leagueStreamCache { leagues[league, default: []] += values.compactMap { displayed[$0.id] } }
            }
        }
        facade.combinedSources = sources
        facade.combinedDisplayIDs = displayIDs
        facade.combinedProviderContexts = Dictionary(ordered.compactMap { context in context.activeProfile.map { ($0.id, context) } },
            uniquingKeysWith: { first, _ in first })
        facade.categories = groups
        facade.streams = channels
        facade.programsByChannel = guide
        facade.professionalStreams = professional
        facade.leagueStreamCache = leagues
        let ready = ordered.contains { $0.automaticMatchingReady }
        facade.channelsValidatedThisSession = ready
        facade.guideValidatedThisSession = ready
        facade.sportsIndexReady = ready
        facade.didCompleteMatching = ready
        facade.refreshCombinedMatches(contexts: ordered, registry: registry)
        facade.restoreCombinedOrders()
        registry.save()
    }

    private func refreshCombinedMatches(contexts: [SportsLibrary], registry: MobileProviderStreamRegistry) {
        var matches: [String: XtreamStream] = [:]
        var teams = profileDefaults.data(forKey: "Lineup.combinedGuide.teamPreferences.v1")
            .flatMap { try? JSONDecoder().decode(TeamChannelPreferences.self, from: $0) }?.entries ?? [:]
        var selections = profileDefaults.data(forKey: "Lineup.combinedGuide.gameSelections.v1")
            .flatMap { try? JSONDecoder().decode(GameChannelSelections.self, from: $0) }?.entries ?? [:]
        teams = teams.filter { combinedSources[$0.value.streamID] != nil }
        selections = selections.filter { combinedSources[$0.value.streamID] != nil }
        for context in contexts {
            guard let profile = context.activeProfile else { continue }
            for (key, pref) in context.teamPreferences.entries {
                let id = registry.id(provider: profile.id, stream: pref.streamID)
                guard combinedSources[id] != nil, teams[key].map({ $0.savedAt < pref.savedAt }) ?? true else { continue }
                teams[key] = TeamChannelPreference(streamID: id, channelName: pref.channelName, teamName: pref.teamName, savedAt: pref.savedAt)
            }
            for (key, pref) in context.gameChannelSelections.entries where selections[key] == nil {
                let id = registry.id(provider: profile.id, stream: pref.streamID)
                if combinedSources[id] != nil { selections[key] = pref.replacingStreamID(id) }
            }
            for game in gamesByLeague.values.joined() where matches[game.id] == nil {
                guard context.eventChannelsReady(for: game), let native = context.stream(for: game) else { continue }
                matches[game.id] = stream(withID: registry.id(provider: profile.id, stream: native.id))
            }
        }
        gameStreamCache = matches
        teamPreferences = TeamChannelPreferences(entries: teams)
        gameChannelSelections = GameChannelSelections(entries: selections)
        gameChannelSelections.prune()
        matchedGameIdentities = matchIdentities(now: Date())
        fastValidatedGameIDs = Set(matches.keys)
    }

    private func restoreCombinedOrders() {
        guideListCache = nil
        let valid = Set(combinedSources.keys)
        let saved = (profileDefaults.array(forKey: "Lineup.combinedGuide.favorites.v1") as? [Int] ?? []).filter { valid.contains($0) }
        let favorites = enabledProfiles.flatMap { profile in
            (combinedProviderContexts[profile.id]?.favoriteStreamOrder ?? []).compactMap {
                combinedDisplayIDs[.init(providerID: profile.id, streamID: $0)]
            }
        }
        favoriteStreamOrder = saved.filter { favorites.contains($0) } + favorites.filter { !saved.contains($0) }
        let savedRecents = (profileDefaults.array(forKey: "Lineup.combinedGuide.recents.v1") as? [Int] ?? []).filter { valid.contains($0) }
        let nativeRecents = enabledProfiles.flatMap { profile in
            (combinedProviderContexts[profile.id]?.recentStreamOrder ?? []).compactMap {
                combinedDisplayIDs[.init(providerID: profile.id, streamID: $0)]
            }
        }
        recentStreamOrder = savedRecents + nativeRecents.filter { !savedRecents.contains($0) }
    }

    nonisolated static func sameProviderConnection(_ lhs: XtreamProfile, _ rhs: XtreamProfile) -> Bool {
        lhs.id == rhs.id && lhs.serverURL == rhs.serverURL && lhs.username == rhs.username
            && lhs.connectionKind == rhs.connectionKind
    }
    #endif

    func removeActiveProfile() {
        guard let profile = activeProfile else { return }
        Task { await removeProfile(profile) }
    }

    func removeProfile(_ profile: XtreamProfile) async {
        guard !isSwitchingProfile, profiles.contains(where: { $0.id == profile.id }) else { return }
        isSwitchingProfile = true
        guard await waitForProviderWork() else { isSwitchingProfile = false; return }
        let removingActive = activeProfile?.id == profile.id
        credentials.delete(profile.id)
        #if os(iOS)
        providerContextLoads[profile.id]?.cancel()
        providerBootstraps[profile.id]?.cancel()
        if let context = providerContexts[profile.id] {
            context.resetProviderState()
            context.activeProfile = nil
            await context.preparedWriteTask?.value
        }
        providerBootstraps[profile.id] = nil
        providerContexts[profile.id] = nil
        providerProblems[profile.id] = nil
        #endif
        passwordCache = nil
        profiles.removeAll { $0.id == profile.id }
        profileDefaults.removeObject(forKey: favoritesKey + "." + profile.id.uuidString)
        profileDefaults.removeObject(forKey: teamPreferencesKey + "." + profile.id.uuidString)
        profileDefaults.removeObject(forKey: gameChannelSelectionsKey + "." + profile.id.uuidString)
        profileDefaults.removeObject(forKey: recentsKey + "." + profile.id.uuidString)
        if removingActive {
            resetProviderState()
            activeProfile = profiles.first
            restoreFavorites()
            restoreTeamPreferences()
            restoreGameChannelSelections()
            restoreRecentChannels()
        }
        // Finish an already queued cache write before deleting this cache.
        await cacheWriteTask?.value
        await preparedWriteTask?.value
        PreparedLiveStore.remove(profileID: profile.id, directory: preparedCacheDirectory)
        Self.removeCaches(profileID: profile.id)
        persistProfiles()
        isSwitchingProfile = false
        if removingActive, activeProfile != nil { await bootstrap() }
    }

    private func resetProviderState() {
        providerGeneration = UUID()
        finishCachedRestore()
        bootstrapInFlight = false
        libraryRefreshInFlight = false
        scheduleRefreshInFlight = false
        guideRefresh?.cancel()
        guideRefresh = nil
        #if os(iOS)
        mobileSportsWork.cancel()
        mobileIndexFacts.restore([:])
        mobileEventCandidates = nil
        #endif
        refreshProgress.cancel()
        measuredPlaybackURLs = [:]
        eventChannelCache = [:]
        // A refresh started for the previous provider must never land in the
        // next one's state. Everything provider-scoped — cached matches,
        // favorites, recent channels, preferences — is re-read from that
        // provider's own keys afterwards.
        backgroundRefresh?.cancel()
        backgroundRefresh = nil
        errorMessage = nil
        indexGeneration = UUID()
        matchGeneration = UUID()
        promoteGeneration = UUID()
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
        preparedMatches = [:]
        eventsNeedingPreparation = []
        dailyPreparedAt = nil
        didRestoreProviderCache = false
        hasFullCatalog = false
        hasFullGuide = false
        preparedPlaylistURLs = [:]
        lastBackgroundRefreshAttempt = nil
        lastSavedMatchIdentities = [:]
        lastSavedMatchDay = nil
        programsByChannel = [:]
        gamesByLeague = [:]
        scheduleLoadedLeagues = []
        scheduleDay = nil
        didRestoreSchedule = false
        scheduleSnapshotAt = nil
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
        if persistsActiveSelection { profileDefaults.set(activeProfile?.id.uuidString, forKey: activeKey) }
        if profileDefaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    func restoreCloudSettings() async {
        guard let data = profileDefaults.data(forKey: profilesKey),
              let saved = try? JSONDecoder().decode([XtreamProfile].self, from: data) else { return }
        let activeID = profileDefaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        profiles = saved
        let selected = saved.first { $0.id == activeID } ?? saved.first
        if selected?.id != activeProfile?.id
            || selected.map({ PreparedLiveSnapshot.connection(for: $0) }) != activeProfile.map({ PreparedLiveSnapshot.connection(for: $0) }) {
            resetProviderState()
            activeProfile = selected
            restoreFavorites()
            restoreTeamPreferences()
            restoreGameChannelSelections()
            restoreRecentChannels()
            if selected != nil { await bootstrap() }
        } else {
            activeProfile = selected
            restoreFavorites()
            restoreTeamPreferences()
            restoreGameChannelSelections()
            restoreRecentChannels()
        }
    }
}
