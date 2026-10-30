import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

@MainActor
final class PreparedLiveMatchesTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory: URL
        let suite: String
        let defaults: UserDefaults
        let profile: XtreamProfile
        let game: SportsGame
        let match: PreparedLiveMatch
        let snapshot: PreparedLiveSnapshot

        func library(hasCredentials: Bool = true, session: URLSession = .shared) -> SportsLibrary {
            SportsLibrary(profileDefaults: defaults,
                credentials: .init(password: { _ in hasCredentials ? "test-only-secret" : nil },
                                   save: { _, _ in }, delete: { _ in }),
                preparedCacheDirectory: directory, automaticRefreshes: false, providerSession: session,
                scheduleCacheLocation: directory.appendingPathComponent("schedule.json"))
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func game(start: Date = Date().addingTimeInterval(-600), broadcast: String = "ABC",
                      state: String = "in", score: String = "10", league: SportsLeague = .nba) -> SportsGame {
        SportsGame(id: "prepared-game", league: league, start: start,
            awayTeam: league == .nhl ? "Columbus Blue Jackets" : "Orlando Magic",
            homeTeam: league == .nhl ? "Carolina Hurricanes" : "Miami Heat",
            awayAbbreviation: league == .nhl ? "CBJ" : "ORL", homeAbbreviation: league == .nhl ? "CAR" : "MIA",
            awayLogo: "", homeLogo: "", awayScore: score, homeScore: "12", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Live", state: state,
            broadcast: broadcast, eventName: nil)
    }

    private func fixture(preparedAt: Date = Date().addingTimeInterval(-30),
                         programEnd: Date = Date().addingTimeInterval(3600), league: SportsLeague = .nba) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreparedLiveTests-\(UUID())")
        let suite = "PreparedLiveTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profile = XtreamProfile(name: "Test lineup", serverURL: "https://prepared.invalid", username: "viewer")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.profiles")
        defaults.set(profile.id.uuidString, forKey: "NullSports.activeProfile")
        let event = game(broadcast: league == .nhl ? "ESPN+" : "ABC", league: league)
        let names = league == .nhl
            ? ["US: NHL Columbus Blue Jackets vs Carolina Hurricanes 4K", "US: NHL Columbus Blue Jackets vs Carolina Hurricanes FHD"]
            : ["US: ABC Miami 4K", "US: ABC Miami FHD"]
        let streams = names.enumerated().map { offset, name in
            XtreamStream(num: nil, name: name, streamType: "live", streamID: offset + 1,
                streamIcon: nil, epgChannelID: "event", categoryID: "sports")
        }
        let programs = ["event": [CurrentProgram(channelID: "event",
            title: league == .nhl ? "NHL Hockey: Columbus Blue Jackets at Carolina Hurricanes" : "NBA Basketball: Orlando Magic at Miami Heat", detail: "",
            start: Date().addingTimeInterval(-1200), end: programEnd)]]
        let alternatives = SportsLibrary.matchingEventChannels(for: event, candidates: streams,
            programs: programs, categories: [.init(categoryID: "sports", categoryName: "Sports")], now: Date())
        XCTAssertEqual(alternatives.count, 2)
        let match = PreparedLiveMatch(preparedAt: preparedAt, eventStart: event.start, identity: PreparedLiveMatch.identity(for: event),
            primary: streams[0], alternatives: alternatives, programs: programs, categoryNames: ["sports": "Sports"])
        let snapshot = PreparedLiveSnapshot(version: PreparedLiveSnapshot.version,
            connection: PreparedLiveSnapshot.connection(for: profile), savedAt: Date(), dailyPreparedAt: preparedAt,
            games: [event.league.rawValue: [event]], loadedLeagues: [event.league.rawValue], matches: [event.id: match])
        PreparedLiveStore.write(snapshot, profileID: profile.id, directory: directory)
        return Fixture(directory: directory, suite: suite, defaults: defaults, profile: profile,
                       game: event, match: match, snapshot: snapshot)
    }

    func testPrimaryAndAlternativesPlayBeforeFullGuideIndexOrProviderValidation() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let library = f.library()
        let restored = await library.restorePreparedMatches()
        XCTAssertTrue(restored)
        XCTAssertFalse(library.automaticMatchingReady, "No full index or network validation took place")
        XCTAssertTrue(library.eventChannelsReady(for: f.game))
        XCTAssertEqual(library.verifiedStream(for: f.game)?.id, 1)
        XCTAssertEqual(library.preparedPlaybackStream(for: f.game)?.id, 1)
        XCTAssertEqual(library.streams.count, 2, "Only the prepared channels were read")
        let channels = await library.eventChannels(for: f.game)
        XCTAssertEqual(channels.map(\.id), [1, 2])
        XCTAssertEqual(channels.map(\.quality.height), [2160, 1080])
        if case let .play(id, source) = library.preferredChannel(for: f.game) {
            XCTAssertEqual(id, 1)
            XCTAssertEqual(source, .verified)
        } else { XCTFail("A saved game must play, even before any refresh") }
        let url = try XCTUnwrap(library.playbackURLs(for: channels[0].stream).first)
        XCTAssertEqual(url.host, "prepared.invalid")
        XCTAssertTrue(url.path.contains("/viewer/test-only-secret/1."))
    }

    #if os(iOS)
    func testBackgroundingCancelsPreparationWithoutWithdrawingSavedPlayback() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let library = f.library()
        _ = await library.restorePreparedMatches()
        library.setPreparationSuspended(true)
        XCTAssertEqual(library.preparedPlaybackStream(for: f.game)?.id, 1)
        XCTAssertNil(library.refreshProgress.status)
        library.refreshProviderIfNeeded()
        XCTAssertFalse(library.channelsAreSyncing)
        library.setPreparationSuspended(false)
        XCTAssertEqual(library.preparedPlaybackStream(for: f.game)?.id, 1)
    }
    #endif

    func testRestoringAgainDoesNotRenewTheDailyPreparationTimestamp() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let first = f.library()
        let restoredFirst = await first.restorePreparedMatches()
        XCTAssertTrue(restoredFirst)
        let second = f.library()
        let restoredSecond = await second.restorePreparedMatches()
        XCTAssertTrue(restoredSecond)
        let saved = try XCTUnwrap(PreparedLiveStore.read(profile: f.profile, directory: f.directory))
        XCTAssertEqual(saved.dailyPreparedAt, f.snapshot.dailyPreparedAt)
        XCTAssertEqual(saved.matches[f.game.id]?.preparedAt, f.match.preparedAt)
    }

    private func replaceMatches(_ matches: [String: PreparedLiveMatch], in f: Fixture) {
        let saved = PreparedLiveSnapshot(version: PreparedLiveSnapshot.version,
            connection: f.snapshot.connection, savedAt: Date(), dailyPreparedAt: f.snapshot.dailyPreparedAt,
            games: f.snapshot.games, loadedLeagues: f.snapshot.loadedLeagues, matches: matches)
        PreparedLiveStore.write(saved, profileID: f.profile.id, directory: f.directory)
    }

    func testCachedEventsAppearEvenWhenNoChannelResultWasSaved() async throws {
        let f = try fixture(league: .nhl)
        defer { f.cleanUp() }
        replaceMatches([:], in: f)
        let library = f.library()
        let restoredMatch = await library.restorePreparedMatches()
        XCTAssertFalse(restoredMatch)
        XCTAssertEqual(library.games(for: .nhl).map(\.id), [f.game.id],
                       "Schedule restore must be independent of successful channel matching")
        XCTAssertTrue(library.scheduleAvailable(for: .nhl))
    }

    func testPreparedAlternativePlaysWithoutAPrimaryOrAnyIndexBuild() async throws {
        let f = try fixture(league: .nhl)
        defer { f.cleanUp() }
        let alternativeOnly = PreparedLiveMatch(preparedAt: f.match.preparedAt, eventStart: f.game.start,
            identity: f.match.identity, primary: nil, alternatives: f.match.alternatives,
            programs: f.match.programs, categoryNames: f.match.categoryNames)
        replaceMatches([f.game.id: alternativeOnly], in: f)
        let library = f.library()
        _ = await library.restorePreparedMatches()
        XCTAssertFalse(library.automaticMatchingReady)
        XCTAssertEqual(library.preparedPlaybackStream(for: f.game)?.id, 1)
        if case .play(1, .verified) = library.preferredChannel(for: f.game) { }
        else { XCTFail("A valid prepared alternative must not open the manual picker") }
        let direct = await library.bestQualityStream(for: f.game, fallback: f.match.alternatives[0].stream)
        XCTAssertEqual(direct?.id, 1, "Prepared playback bypasses discovery altogether")
    }

    func testExpiredPrimaryUsesThePreparedAlternativeInsteadOfThePicker() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let primary = try XCTUnwrap(f.match.primary)
        let original = try XCTUnwrap(f.match.programs["event"]?.first)
        let expired = CurrentProgram(channelID: "event", title: original.title, detail: "",
            start: original.start, end: Date().addingTimeInterval(-1))
        let alternate = XtreamStream(num: nil, name: "US: ABC Miami FHD", streamType: "live", streamID: 2,
            streamIcon: nil, epgChannelID: "alternate", categoryID: "sports")
        let listing = CurrentProgram(channelID: "alternate", title: original.title, detail: "",
                                     start: original.start, end: original.end)
        let entry = LiveEventChannel(stream: alternate, program: listing, evidence: 300, quality: .init(name: alternate.name))
        let saved = PreparedLiveMatch(preparedAt: f.match.preparedAt, eventStart: f.game.start,
            identity: f.match.identity, primary: primary, alternatives: [entry],
            programs: ["event": [expired], "alternate": [listing]], categoryNames: f.match.categoryNames)
        replaceMatches([f.game.id: saved], in: f)
        let library = f.library()
        _ = await library.restorePreparedMatches()
        XCTAssertEqual(library.preparedPlaybackStream(for: f.game)?.id, 2)
        if case .play(2, .verified) = library.preferredChannel(for: f.game) { }
        else { XCTFail("The prepared fallback should play without waiting for a refresh") }
    }

    func testExistingNHLMatchUpgradesLocallyBeforeAnyProviderRefresh() async throws {
        struct Channels: Encodable { let categories: [XtreamCategory]; let streams: [XtreamStream] }
        struct Guide: Encodable { let programsByChannel: [String: [CurrentProgram]] }
        struct Schedule: Encodable { let savedAt: Date; let games: [String: [SportsGame]] }
        struct State: Encodable {
            let guideUpdatedAt: Date
            let libraryUpdatedAt: Date
            let matchCacheVersion = 2
            let dailyMatches: DailyGameMatches<XtreamStream>
        }
        let f = try fixture(league: .nhl)
        defer { f.cleanUp() }
        PreparedLiveStore.remove(profileID: f.profile.id, directory: f.directory)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let prefix = "lineup-" + f.profile.id.uuidString
        let channels = cache.appendingPathComponent(prefix + "-channels.json")
        let guide = cache.appendingPathComponent(prefix + "-guide.json")
        let state = cache.appendingPathComponent(prefix + "-state.json")
        defer { for file in [channels, guide, state] { try? FileManager.default.removeItem(at: file) } }
        try JSONEncoder().encode(Channels(categories: [.init(categoryID: "sports", categoryName: "Sports")],
                                         streams: f.match.streams)).write(to: channels, options: .atomic)
        try JSONEncoder().encode(Guide(programsByChannel: f.match.programs)).write(to: guide, options: .atomic)
        try JSONEncoder().encode(Schedule(savedAt: Date(), games: f.snapshot.games))
            .write(to: f.directory.appendingPathComponent("schedule.json"), options: .atomic)
        let oldIdentity = ["quality-v1", "nhl", "Columbus Blue Jackets", "Carolina Hurricanes", "CBJ", "CAR",
                           "ESPN+", "", "", "", String(f.game.start.timeIntervalSince1970)]
        let oldMatch = DailyGameMatches(savedAt: f.match.preparedAt,
            identities: [f.game.id: oldIdentity],
            channels: [f.game.id: try XCTUnwrap(f.match.primary)])
        try JSONEncoder().encode(State(guideUpdatedAt: Date(), libraryUpdatedAt: Date(), dailyMatches: oldMatch))
            .write(to: state, options: .atomic)
        let library = f.library()
        await library.bootstrap()
        XCTAssertFalse(library.automaticMatchingReady)
        XCTAssertEqual(library.preparedPlaybackStream(for: f.game)?.id, 1)
        XCTAssertEqual(PreparedLiveStore.read(profile: f.profile, directory: f.directory)?.matches[f.game.id]?.primary?.id, 1)
        let reopened = f.library()
        let restored = await reopened.restorePreparedMatches()
        XCTAssertTrue(restored)
        XCTAssertEqual(reopened.preparedPlaybackStream(for: f.game)?.id, 1)
    }

    func testFailedChannelAndGuideRefreshKeepPreparedPlaybackAndTheLastDiskSnapshot() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreparedOfflineProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let library = f.library(session: session)
        _ = await library.restorePreparedMatches()
        await library.reload()
        XCTAssertFalse(library.isGuideLoading)
        XCTAssertNil(library.errorMessage, "A failed background refresh must not interrupt a usable lineup")
        XCTAssertEqual(library.verifiedStream(for: f.game)?.id, 1)
        let channels = await library.eventChannels(for: f.game)
        XCTAssertEqual(channels.map(\.id), [1, 2])
        let saved = try XCTUnwrap(PreparedLiveStore.read(profile: f.profile, directory: f.directory))
        XCTAssertEqual(saved.savedAt, f.snapshot.savedAt, "A failed refresh cannot replace the last good disk snapshot")
    }

    func testSavedGamePlaysWhileGuideIsHeldAndNewAlternativeArrivesAfterRefresh() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let requested = expectation(description: "Guide request is running")
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyyMMddHHmmss Z"
        let program = try XCTUnwrap(f.match.programs["event"]?.first)
        let xml = "<tv><programme channel=\"event\" start=\"\(date.string(from: program.start))\" stop=\"\(date.string(from: program.end))\"><title>NBA Basketball: Orlando Magic at Miami Heat</title></programme></tv>"
        let added = XtreamStream(num: nil, name: "US: ABC Miami 8K", streamType: "live", streamID: 3,
                                 streamIcon: nil, epgChannelID: "event", categoryID: "sports")
        let scenario = PreparedRefreshScenario(categories: try JSONEncoder().encode([
            XtreamCategory(categoryID: "sports", categoryName: "Sports")]),
            streams: try JSONEncoder().encode(f.match.streams + [added]), guide: Data(xml.utf8),
            onGuide: { requested.fulfill() })
        PreparedRefreshProtocol.scenario = scenario
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreparedRefreshProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { scenario.release(); PreparedRefreshProtocol.scenario = nil; session.invalidateAndCancel() }
        let library = f.library(session: session)
        _ = await library.restorePreparedMatches()
        let refresh = Task { await library.reload() }
        await fulfillment(of: [requested], timeout: 5)
        XCTAssertTrue(library.isGuideLoading)
        XCTAssertEqual(library.verifiedStream(for: f.game)?.id, 1, "Guide I/O must not gate the saved game")
        XCTAssertEqual(library.preparedPlaybackStream(for: f.game)?.id, 1)
        if case .play(1, .verified) = library.preferredChannel(for: f.game) { }
        else { XCTFail("A stalled EPG must not turn a cached game tap into a wait or picker") }
        let whileLoading = await library.eventChannels(for: f.game)
        XCTAssertEqual(whileLoading.map(\.id), [1, 2])
        scenario.release()
        await refresh.value
        let updated = await library.eventChannels(for: f.game)
        XCTAssertEqual(updated.map(\.id), [3, 1, 2], "A channel addition prepares this event again")
        XCTAssertEqual(library.verifiedStream(for: f.game)?.id, 3)
    }

    func testOlderLargeCatalogAndGuideCannotWithdrawPreparedPlaybackDuringBootstrap() async throws {
        struct Channels: Encodable { let categories: [XtreamCategory]; let streams: [XtreamStream] }
        struct Guide: Encodable { let programsByChannel: [String: [CurrentProgram]] }
        let f = try fixture()
        defer { f.cleanUp() }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let prefix = "lineup-" + f.profile.id.uuidString
        let channelsURL = cache.appendingPathComponent(prefix + "-channels.json")
        let guideURL = cache.appendingPathComponent(prefix + "-guide.json")
        defer {
            try? FileManager.default.removeItem(at: channelsURL)
            try? FileManager.default.removeItem(at: guideURL)
        }
        let stale = (1...26_000).map { id in
            XtreamStream(num: nil, name: "Older channel \(id)", streamType: "live", streamID: id,
                         streamIcon: nil, epgChannelID: id <= 2 ? "event" : nil, categoryID: "sports")
        }
        try JSONEncoder().encode(Channels(categories: [.init(categoryID: "sports", categoryName: "Sports")],
                                         streams: stale)).write(to: channelsURL, options: .atomic)
        let oldProgram = CurrentProgram(channelID: "event", title: "Other teams", detail: "",
            start: Date().addingTimeInterval(-1200), end: Date().addingTimeInterval(3600))
        try JSONEncoder().encode(Guide(programsByChannel: ["event": [oldProgram]])).write(to: guideURL, options: .atomic)
        let library = f.library()
        await library.bootstrap()
        XCTAssertEqual(library.streams.count, 26_000)
        XCTAssertEqual(library.verifiedStream(for: f.game)?.id, 1)
        let alternatives = await library.eventChannels(for: f.game)
        XCTAssertEqual(alternatives.map(\.id), [1, 2])
    }

    func testCacheIsBoundToTheAccountConnectionAndRequiresCredentials() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        var changed = f.profile
        changed.username = "someone-else"
        XCTAssertNil(PreparedLiveStore.read(profile: changed, directory: f.directory))
        changed = f.profile
        changed.serverURL = "https://another.invalid"
        XCTAssertNil(PreparedLiveStore.read(profile: changed, directory: f.directory))
        changed = f.profile
        changed.connectionKind = "m3u"
        XCTAssertNil(PreparedLiveStore.read(profile: changed, directory: f.directory))
        changed = f.profile
        changed.name = "Renamed lineup"
        XCTAssertNotNil(PreparedLiveStore.read(profile: changed, directory: f.directory))
        let withoutCredentials = f.library(hasCredentials: false)
        let restored = await withoutCredentials.restorePreparedMatches()
        XCTAssertFalse(restored)
        XCTAssertNil(withoutCredentials.verifiedStream(for: f.game))
    }

    func testDisabledProviderCannotRestorePreparedPlayback() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        f.defaults.set([f.profile.id.uuidString], forKey: "Lineup.disabledIPTVProviders.v1")
        let restored = await f.library().restorePreparedMatches()
        XCTAssertFalse(restored)
    }

    func testScheduleChangesInvalidateOnlyTheChangedEventIdentity() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let scoreOnly = game(start: f.game.start, score: "30")
        XCTAssertTrue(f.match.isCurrent(identity: PreparedLiveMatch.identity(for: scoreOnly), now: Date()))
        let rescheduled = game(start: f.game.start.addingTimeInterval(3600))
        XCTAssertFalse(f.match.isCurrent(identity: PreparedLiveMatch.identity(for: rescheduled), now: Date()))
        let newBroadcast = game(start: f.game.start, broadcast: "ESPN")
        XCTAssertFalse(f.match.isCurrent(identity: PreparedLiveMatch.identity(for: newBroadcast), now: Date()))
    }

    func testChangedGuideRecycledSlotsAndRemovedChannelsRequirePreparationAgain() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let available = Dictionary(uniqueKeysWithValues: f.match.streams.map { ($0.id, $0) })
        func agrees(_ channels: [Int: XtreamStream], _ guide: [String: [CurrentProgram]]) -> Bool {
            f.match.agreesWith(streams: channels, programs: guide, categories: f.match.categoryNames, checkGuide: true)
        }
        XCTAssertTrue(agrees(available, f.match.programs))
        var otherGuide = f.match.programs
        otherGuide["unrelated"] = [.init(channelID: "unrelated", title: "News", detail: "",
            start: Date(), end: Date().addingTimeInterval(600))]
        XCTAssertTrue(agrees(available, otherGuide), "An unrelated EPG update keeps the prepared event")
        var sameChannel = f.match.programs
        sameChannel["event", default: []].append(.init(channelID: "event", title: "Evening News", detail: "",
            start: Date().addingTimeInterval(7200), end: Date().addingTimeInterval(10800)))
        XCTAssertTrue(agrees(available, sameChannel), "Later unrelated shows on the same broadcaster do not rematch this game")
        otherGuide["event"] = [.init(channelID: "event", title: "Boston Celtics at Chicago Bulls", detail: "",
            start: Date().addingTimeInterval(-1200), end: Date().addingTimeInterval(3600))]
        XCTAssertFalse(agrees(available, otherGuide))
        var recycled = available
        recycled[1] = .init(num: nil, name: "NBA Boston Celtics vs Chicago Bulls", streamType: "live",
            streamID: 1, streamIcon: nil, epgChannelID: "event", categoryID: "sports")
        XCTAssertFalse(agrees(recycled, f.match.programs))
        recycled = available
        recycled.removeValue(forKey: 2)
        XCTAssertFalse(agrees(recycled, f.match.programs))
    }

    func testExpiredProgramCannotAuthorizePlaybackEvenWhenDailyCacheHasNotExpired() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let end = try XCTUnwrap(f.match.programs["event"]?.first?.end)
        XCTAssertTrue(f.match.covers(f.game, now: Date()))
        XCTAssertFalse(f.match.covers(f.game, now: end))
        XCTAssertTrue(PreparedMatchPolicy.canUse(preparedAt: f.match.preparedAt, now: end))
    }

    func testTooOldAndFutureSnapshotsDoNotRestore() async throws {
        for preparedAt in [Date().addingTimeInterval(-48 * 3600), Date().addingTimeInterval(3600)] {
            let f = try fixture(preparedAt: preparedAt)
            let restored = await f.library().restorePreparedMatches()
            XCTAssertFalse(restored)
            f.cleanUp()
        }
    }

    func testCorruptSnapshotIsIgnoredAndANewAtomicWriteRepairsIt() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let file = PreparedLiveStore.url(profileID: f.profile.id, directory: f.directory)
        try Data("{broken".utf8).write(to: file)
        XCTAssertNil(PreparedLiveStore.read(profile: f.profile, directory: f.directory))
        PreparedLiveStore.write(f.snapshot, profileID: f.profile.id, directory: f.directory)
        XCTAssertEqual(PreparedLiveStore.read(profile: f.profile, directory: f.directory)?.matches[f.game.id]?.primary?.id, 1)
    }

    func testRemovingProviderDeletesItsDurablePlaybackSnapshot() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let library = f.library()
        _ = await library.restorePreparedMatches()
        await library.removeProfile(f.profile)
        XCTAssertNil(PreparedLiveStore.read(profile: f.profile, directory: f.directory))
        XCTAssertNil(library.verifiedStream(for: f.game))
    }

    func testRetiringAnAlternativeKeepsThePrimaryAndRetiringPrimaryUsesVerifiedAlternative() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let primaryOnly = f.match.retaining([1])
        XCTAssertEqual(primaryOnly.primary?.id, 1)
        XCTAssertEqual(primaryOnly.alternatives.map(\.id), [1])
        XCTAssertEqual(primaryOnly.preparedAt, f.match.preparedAt)
        let alternateOnly = f.match.retaining([2])
        XCTAssertEqual(alternateOnly.primary?.id, 2)
        XCTAssertEqual(alternateOnly.alternatives.map(\.id), [2])
    }

    func testAnOlderWriterCannotReplaceANewerSnapshot() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let older = PreparedLiveSnapshot(version: PreparedLiveSnapshot.version,
            connection: f.snapshot.connection, savedAt: f.snapshot.savedAt.addingTimeInterval(-1),
            dailyPreparedAt: nil, games: [:], loadedLeagues: [], matches: [:])
        PreparedLiveStore.write(older, profileID: f.profile.id, directory: f.directory)
        let saved = try XCTUnwrap(PreparedLiveStore.read(profile: f.profile, directory: f.directory))
        XCTAssertEqual(saved.matches[f.game.id]?.primary?.id, 1)
        XCTAssertEqual(saved.savedAt, f.snapshot.savedAt)
    }

    func testPlaylistSourceAddressesAreEncryptedAndBoundToTheirCredential() throws {
        let url = try XCTUnwrap(URL(string: "https://playlist.invalid/private-token/live.m3u8"))
        let encrypted = try XCTUnwrap(PreparedPlaylistSources.seal([7: url], secret: "test-secret"))
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("private-token"))
        XCTAssertEqual(PreparedPlaylistSources.open(encrypted, secret: "test-secret"), [7: url])
        XCTAssertTrue(PreparedPlaylistSources.open(encrypted, secret: "other-secret").isEmpty)
        XCTAssertTrue(PreparedPlaylistSources.open(Data("broken".utf8), secret: "test-secret").isEmpty)
    }

    #if os(iOS)
    func testReadyPrimaryDoesNotWaitForAnEarlierCatalogRequest() async throws {
        let f = try fixture(league: .nhl)
        defer { f.cleanUp() }
        PreparedLiveStore.remove(profileID: f.profile.id, directory: f.directory)
        let started = expectation(description: "Older catalog request started")
        let ready = expectation(description: "Prepared primary published before that request finishes")
        let gate = PreparedCatalogGate()
        defer { Task { await gate.release() } }
        let snapshot = MobileProviderSnapshot(categories: [.init(categoryID: "sports", categoryName: "Sports")],
            streams: f.match.streams, programs: f.match.programs, fetchedAt: Date())
        let catalog = MobileProviderCatalog { _, _ in
            started.fulfill()
            await gate.wait()
            return snapshot
        }
        let root = f.library()
        let old = Task { await root.providerContext(id: f.profile.id, catalog: catalog) }
        await fulfillment(of: [started], timeout: 5)
        PreparedLiveStore.write(f.snapshot, profileID: f.profile.id, directory: f.directory)
        _ = await root.restorePreparedMatches()
        let cached = Task {
            let context = await root.providerContext(id: f.profile.id, catalog: catalog)
            XCTAssertEqual(context?.preparedPlaybackStream(for: f.game)?.id, 1)
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 5)
        await gate.release()
        await cached.value
        _ = await old.value
    }

    func testColdCombinedSportsPublishesCachedEventsWithoutWaitingForRootBootstrap() async throws {
        let f = try fixture(league: .nhl)
        defer { f.cleanUp() }
        let root = f.library()
        XCTAssertTrue(root.gamesByLeague.isEmpty)
        let catalog = MobileProviderCatalog { _, _ in
            XCTFail("A cached launch must not request a provider catalog before showing its games")
            throw URLError(.cannotConnectToHost)
        }
        let combined = await root.combinedGuide(catalog: catalog)
        XCTAssertEqual(combined.games(for: .nhl).map(\.id), [f.game.id])
        let selected = try XCTUnwrap(combined.preparedPlaybackStream(for: f.game))
        XCTAssertEqual(combined.playbackSource(for: selected).stream.id, 1)
        if case .play(_, .verified) = combined.preferredChannel(for: f.game) { }
        else { XCTFail("The first cached tap must play without full-guide or root-bootstrap completion") }
    }

    func testCombinedPlaybackUsesAnotherPreparedProviderWhenTheFirstCannotVerifyTheGame() async throws {
        let f = try fixture(league: .nhl)
        defer { f.cleanUp() }
        let second = XtreamProfile(name: "Working lineup", serverURL: "https://working.invalid", username: "other")
        f.defaults.set(try JSONEncoder().encode([f.profile, second]), forKey: "NullSports.profiles")
        // The first provider has only an unplayable prepared result. It must
        // not mask a ready source from another enabled account.
        let stalePrimary = XtreamStream(num: nil, name: "US: ESPN FHD", streamType: "live", streamID: 1,
            streamIcon: nil, epgChannelID: "wrong", categoryID: "sports")
        let wrong = CurrentProgram(channelID: "wrong", title: "NHL Hockey: Boston Bruins at New York Rangers", detail: "",
            start: Date().addingTimeInterval(-1200), end: Date().addingTimeInterval(3600))
        let noFeed = PreparedLiveMatch(preparedAt: f.match.preparedAt, eventStart: f.game.start,
            identity: f.match.identity, primary: stalePrimary, alternatives: [],
            programs: ["wrong": [wrong]], categoryNames: f.match.categoryNames)
        replaceMatches([f.game.id: noFeed], in: f)
        let other = PreparedLiveSnapshot(version: PreparedLiveSnapshot.version,
            connection: PreparedLiveSnapshot.connection(for: second), savedAt: Date(),
            dailyPreparedAt: f.snapshot.dailyPreparedAt, games: f.snapshot.games,
            loadedLeagues: f.snapshot.loadedLeagues, matches: f.snapshot.matches)
        PreparedLiveStore.write(other, profileID: second.id, directory: f.directory)
        let root = f.library()
        _ = await root.restorePreparedMatches()
        let catalog = MobileProviderCatalog { _, _ in
            XCTFail("Both accounts have prepared local results")
            throw URLError(.cannotConnectToHost)
        }
        let combined = await root.combinedGuide(catalog: catalog)
        let selected = try XCTUnwrap(combined.preparedPlaybackStream(for: f.game))
        let source = combined.playbackSource(for: selected)
        XCTAssertEqual(source.library.activeProfile?.id, second.id)
        XCTAssertEqual(source.stream.id, 1)
        if case .play(_, .verified) = combined.preferredChannel(for: f.game) { }
        else { XCTFail("A prepared source in another account must not open the picker") }
    }

    func testCombinedLineupRestoresBothProvidersWithOverlappingIDsWithoutCatalogRequests() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let second = XtreamProfile(name: "Other lineup", serverURL: "https://other-prepared.invalid", username: "other")
        f.defaults.set(try JSONEncoder().encode([f.profile, second]), forKey: "NullSports.profiles")
        let saved = PreparedLiveSnapshot(version: PreparedLiveSnapshot.version,
            connection: PreparedLiveSnapshot.connection(for: second), savedAt: Date(),
            dailyPreparedAt: f.snapshot.dailyPreparedAt, games: f.snapshot.games,
            loadedLeagues: f.snapshot.loadedLeagues, matches: f.snapshot.matches)
        PreparedLiveStore.write(saved, profileID: second.id, directory: f.directory)
        let root = f.library()
        _ = await root.restorePreparedMatches()
        let catalog = MobileProviderCatalog { _, _ in
            XCTFail("Saved playback must not wait for a provider catalog request")
            throw URLError(.cannotConnectToHost)
        }
        let combined = await root.combinedGuide(catalog: catalog)
        XCTAssertTrue(combined.eventChannelsReady(for: f.game))
        XCTAssertNotNil(combined.verifiedStream(for: f.game))
        let alternatives = await combined.eventChannels(for: f.game)
        XCTAssertEqual(alternatives.count, 4)
        XCTAssertEqual(Set(alternatives.map(\.id)).count, 4)
        let catalogRevision = combined.streamsRevision
        let unchanged = await root.combinedGuide(catalog: catalog)
        XCTAssertEqual(unchanged.streamsRevision, catalogRevision,
                       "Unchanged prepared proof must not republish the entire combined catalog")
        let sources = alternatives.map { combined.playbackSource(for: $0.stream) }
        XCTAssertEqual(Set(sources.compactMap { $0.library.activeProfile?.id }), [f.profile.id, second.id])
        for source in sources {
            XCTAssertTrue([1, 2].contains(source.stream.id))
            let url = try XCTUnwrap(source.library.playbackURLs(for: source.stream).first)
            let isFirst = source.library.activeProfile?.id == f.profile.id
            XCTAssertEqual(url.host, isFirst ? "prepared.invalid" : "other-prepared.invalid")
            XCTAssertTrue(url.path.contains(isFirst ? "/viewer/" : "/other/"))
        }
    }
    #endif
}

private actor PreparedCatalogGate {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        released = true
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume() }
    }
}

private final class PreparedOfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private final class PreparedRefreshScenario: @unchecked Sendable {
    let categories: Data
    let streams: Data
    let guide: Data
    let onGuide: @Sendable () -> Void
    private let lock = NSLock()
    private var released = false
    private var pending: (() -> Void)?

    init(categories: Data, streams: Data, guide: Data, onGuide: @escaping @Sendable () -> Void) {
        self.categories = categories; self.streams = streams; self.guide = guide; self.onGuide = onGuide
    }

    func hold(_ response: @escaping () -> Void) {
        lock.lock()
        let ready = released
        if !ready { pending = response }
        lock.unlock()
        onGuide()
        if ready { response() }
    }

    func release() {
        lock.lock()
        released = true
        let response = pending
        pending = nil
        lock.unlock()
        response?()
    }
}

private final class PreparedRefreshProtocol: URLProtocol {
    static var scenario: PreparedRefreshScenario?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let scenario = Self.scenario, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if url.lastPathComponent == "xmltv.php" {
            scenario.hold { [weak self] in self?.respond(scenario.guide, type: "application/xml") }
        } else {
            let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "action" }?.value
            respond(action == "get_live_categories" ? scenario.categories : scenario.streams, type: "application/json")
        }
    }
    private func respond(_ data: Data, type: String) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": type, "Content-Length": String(data.count)]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
