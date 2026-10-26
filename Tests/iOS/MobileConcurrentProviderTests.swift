import XCTest
@testable import LineupiOS

@MainActor
final class MobileConcurrentProviderTests: XCTestCase {
    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let root: SportsLibrary
        let first: XtreamProfile
        let second: XtreamProfile
        let vault: ConcurrentProviderVault
        let catalog: MobileProviderCatalog
    }

    private func fixture(gate: ConcurrentProviderGate? = nil, failFirst: Bool = false,
                         onLoad: (@Sendable (UUID) -> Void)? = nil) throws -> Fixture {
        let suite = "ConcurrentProviders.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        let first = XtreamProfile(name: "First IPTV", serverURL: "https://first.invalid", username: "first-user")
        let second = XtreamProfile(name: "Second IPTV", serverURL: "https://second.invalid", username: "second-user")
        store.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.profiles")
        store.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        let vault = ConcurrentProviderVault(values: [first.id: "first-test-secret", second.id: "second-test-secret"])
        let snapshots = Dictionary(uniqueKeysWithValues: [first, second].map { profile in
            let stream = XtreamStream(num: 1, name: "Event Channel HD", streamType: "live", streamID: 7,
                streamIcon: nil, epgChannelID: "same-epg", categoryID: "same-category", tvArchive: true, archiveDays: 7)
            let program = CurrentProgram(channelID: "same-epg", title: "\(profile.name) Programme", detail: "",
                start: Date().addingTimeInterval(-300), end: Date().addingTimeInterval(3000))
            return (profile.id, MobileProviderSnapshot(categories: [.init(categoryID: "same-category", categoryName: "Sports")],
                streams: [stream], programs: ["same-epg": [program]], fetchedAt: Date()))
        })
        let catalog = MobileProviderCatalog { profile, _ in
            onLoad?(profile.id)
            if let gate { await gate.wait() }
            if failFirst && profile.id == first.id { throw URLError(.cannotConnectToHost) }
            guard let snapshot = snapshots[profile.id] else { throw URLError(.badServerResponse) }
            return snapshot
        }
        return Fixture(suite: suite, defaults: store,
            root: SportsLibrary(profileDefaults: store, credentials: vault.store),
            first: first, second: second, vault: vault, catalog: catalog)
    }

    func testBothProvidersAreEnabledAndGuideKeepsTheirIDsGuideAndAuthenticationSeparate() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        XCTAssertEqual(f.root.enabledProfiles.map(\.id), [f.first.id, f.second.id])
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        XCTAssertEqual(guide.streams.count, 2)
        XCTAssertEqual(Set(guide.streams.map(\.id)).count, 2)
        XCTAssertEqual(Set(guide.streams.compactMap(\.epgChannelID)).count, 2)
        XCTAssertEqual(Set(guide.categories.map(\.id)).count, 2)
        for stream in guide.streams {
            let source = guide.playbackSource(for: stream)
            XCTAssertEqual(source.stream.id, 7, "Native channel ID must never be replaced by a display ID")
            let profile = try XCTUnwrap(source.library.activeProfile)
            let first = profile.id == f.first.id
            let url = try XCTUnwrap(guide.playbackURLs(for: stream).first)
            XCTAssertEqual(url.host, first ? "first.invalid" : "second.invalid")
            XCTAssertEqual(url.path, first ? "/live/first-user/first-test-secret/7.m3u8" : "/live/second-user/second-test-secret/7.m3u8")
            XCTAssertEqual(guide.guidePrograms(for: stream).map(\.title), ["\(profile.name) Programme"])
            XCTAssertEqual(guide.providerName(for: stream), profile.name)
            let sourceCategory = guide.categorySource(for: try XCTUnwrap(stream.categoryID))
            XCTAssertEqual(sourceCategory.profileID, profile.id)
            XCTAssertEqual(sourceCategory.categoryID, "same-category")
            let replay = try XCTUnwrap(guide.catchUpURLs(for: stream, from: Date().addingTimeInterval(-600),
                until: Date(), in: TimeZone(secondsFromGMT: 0)!).first)
            XCTAssertEqual(replay.host, url.host)
            XCTAssertTrue(replay.path.contains("/\(profile.username)/\(first ? "first-test-secret" : "second-test-secret")/"))
            XCTAssertTrue(replay.path.hasSuffix("/7.ts"))
        }
        XCTAssertEqual(f.root.activeProfile?.id, f.first.id)
        XCTAssertEqual(f.defaults.string(forKey: "NullSports.activeProfile"), f.first.id.uuidString)
    }

    func testSearchKeepsBothServicesAndNamesEachChannelAndProgrammeResult() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        let groups = Dictionary(uniqueKeysWithValues: guide.categories.map { ($0.id, $0.categoryName) })
        let snapshot = AppSearch.LiveSnapshot(channels: guide.streams, groups: groups,
            programs: guide.programsByChannel, games: [], providers: guide.searchProviderInfo)
        for query in ["Event Channel", "Programme"] {
            let hits = AppSearch.live(query, in: snapshot)
            XCTAssertEqual(hits.count, 2)
            XCTAssertEqual(Set(hits.map(\.id)).count, 2)
            XCTAssertEqual(Set(hits.compactMap(\.providerID)), [f.first.id, f.second.id])
            XCTAssertEqual(Set(hits.compactMap(\.providerName)), [f.first.name, f.second.name])
        }
        let game = SportsGame(id: "same-game", league: .nba, start: Date().addingTimeInterval(-600),
            awayTeam: "Orlando Magic", homeTeam: "Miami Heat", awayAbbreviation: "ORL", homeAbbreviation: "MIA",
            awayLogo: "", homeLogo: "", awayScore: "1", homeScore: "2", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Live", state: "in", broadcast: "ABC", eventName: nil)
        let events = AppSearch.LiveSnapshot(channels: [], groups: [:], programs: [:],
            games: guide.streams.map { (game, Optional($0)) }, providers: guide.searchProviderInfo)
        let found = AppSearch.live("Miami", in: events)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.id)).count, 2)
        XCTAssertEqual(Set(found.compactMap(\.providerID)), [f.first.id, f.second.id])
    }

    func testFavoritesRecentsAndStableDisplayIDsSurviveRelaunchWithoutChangingPreferredProvider() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        let first = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.first.id })
        let second = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.second.id })
        guide.addFavorite(second)
        guide.recordRecentChannel(second)
        XCTAssertTrue(guide.isFavorite(second))
        XCTAssertFalse(guide.isFavorite(first))
        XCTAssertEqual(f.defaults.array(forKey: "NullSports.favoriteStreams.\(f.second.id)") as? [Int], [7])
        XCTAssertEqual(f.defaults.array(forKey: "NullSports.favoriteStreams.\(f.first.id)") as? [Int] ?? [], [])
        XCTAssertEqual(f.defaults.array(forKey: "NullSports.recentChannels.\(f.second.id)") as? [Int], [7])
        guide.addFavorite(first)
        guide.moveFavorite(first, offset: -1)
        let expected = guide.favoriteStreamOrder
        f.defaults.set(try JSONEncoder().encode([f.second, f.first]), forKey: "NullSports.profiles")
        let restored = SportsLibrary(profileDefaults: f.defaults, credentials: f.vault.store)
        let again = await restored.combinedGuide(catalog: f.catalog)
        XCTAssertEqual(again.favoriteStreamOrder, expected)
        XCTAssertEqual(again.recentStreams.first?.id, second.id)
        XCTAssertEqual(again.playbackSource(for: try XCTUnwrap(again.stream(withID: first.id))).library.activeProfile?.id, f.first.id)
        XCTAssertEqual(again.playbackSource(for: try XCTUnwrap(again.stream(withID: second.id))).library.activeProfile?.id, f.second.id)
        XCTAssertEqual(restored.activeProfile?.id, f.first.id)
        XCTAssertEqual(f.defaults.string(forKey: "NullSports.activeProfile"), f.first.id.uuidString)
    }

    func testEachFavoritesReorderMoveInTheCombinedGuideIsSavedAsItLands() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        let first = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.first.id })
        let second = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.second.id })
        guide.addFavorite(first)
        guide.addFavorite(second)
        // The reorder sheet keeps its own copy of the rows and moves them as
        // each drag lands, then hands the order before that drag to the guide.
        let listed = guide.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
        XCTAssertEqual(listed.map(\.id), [first.id, second.id])
        guide.moveFavorites(listed, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(guide.favoriteStreamOrder, [second.id, first.id])
        // The next drag starts from where the first left the rows.
        guide.moveFavorites([second, first], fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(guide.favoriteStreamOrder, [first.id, second.id])
        guide.moveFavorites([first, second], fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(guide.favoriteStreamOrder, [second.id, first.id])
        XCTAssertEqual(guide.guideStreams(categoryID: nil, favoritesOnly: true, query: "").map(\.id), [second.id, first.id])

        let restored = SportsLibrary(profileDefaults: f.defaults, credentials: f.vault.store)
        let again = await restored.combinedGuide(catalog: f.catalog)
        XCTAssertEqual(again.favoriteStreamOrder, [second.id, first.id], "Every move was saved; closing confirms nothing")
        XCTAssertEqual(f.defaults.array(forKey: "NullSports.favoriteStreams.\(f.first.id)") as? [Int], [7])
        XCTAssertEqual(f.defaults.array(forKey: "NullSports.favoriteStreams.\(f.second.id)") as? [Int], [7])
    }

    func testDisablingProviderRetiresOnlyItsURLsAndPreservesOtherProviderAndSavedAccount() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        let first = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.first.id })
        let second = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.second.id })
        f.root.setProviderEnabled(f.second.id, enabled: false)
        XCTAssertTrue(guide.playbackURLs(for: second).isEmpty)
        XCTAssertFalse(guide.playbackURLs(for: first).isEmpty)
        let updated = await f.root.combinedGuide(catalog: f.catalog)
        XCTAssertEqual(updated.streams.map(\.id), [first.id])
        let restored = SportsLibrary(profileDefaults: f.defaults, credentials: f.vault.store)
        XCTAssertEqual(restored.enabledProfiles.map(\.id), [f.first.id])
        XCTAssertEqual(restored.profiles.count, 2)
        XCTAssertEqual(f.vault.values[f.second.id], "second-test-secret")
        f.root.setProviderEnabled(f.second.id, enabled: true)
        let enabled = await f.root.combinedGuide(catalog: f.catalog)
        XCTAssertEqual(Set(enabled.streams.map(\.id)), [first.id, second.id])
        XCTAssertEqual(f.root.activeProfile?.id, f.first.id)
    }

    func testDisablingOrRemovingAnAccountDuringDiscoveryRejectsItsLateContext() async throws {
        let started = expectation(description: "provider metadata request started")
        let gate = ConcurrentProviderGate()
        let f = try fixture(gate: gate, onLoad: { _ in started.fulfill() })
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let lookup = Task { await f.root.providerContext(id: f.second.id, catalog: f.catalog) }
        await fulfillment(of: [started], timeout: 5)
        f.root.setProviderEnabled(f.second.id, enabled: false)
        await gate.open()
        let disabled = await lookup.value
        XCTAssertNil(disabled)
        let startedRemoval = expectation(description: "removed account request started")
        let removalGate = ConcurrentProviderGate()
        let g = try fixture(gate: removalGate, onLoad: { _ in startedRemoval.fulfill() })
        defer { g.defaults.removePersistentDomain(forName: g.suite) }
        let removedLookup = Task { await g.root.providerContext(id: g.second.id, catalog: g.catalog) }
        await fulfillment(of: [startedRemoval], timeout: 5)
        await g.root.removeProfile(g.second)
        await removalGate.open()
        let removed = await removedLookup.value
        XCTAssertNil(removed)
        XCTAssertEqual(g.root.activeProfile?.id, g.first.id)
        XCTAssertEqual(g.root.profiles.map(\.id), [g.first.id])
    }

    func testLegacyCategoryDefaultsResolveToOnlyTheirOwnProviderInCombinedGuide() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        let saved = MobileGuideDefaultCategory.setting("same-category", for: f.second.id, in: "{}")
        let value = MobileGuideDefaultCategory.initialFilter(for: f.second.id, in: saved,
            categoryIDs: guide.categories.map(\.id), hasFavorites: false)
        XCTAssertEqual(value, .category("\(f.second.id.uuidString)|same-category"))
        XCTAssertEqual(guide.guideStreams(categoryID: value.categoryID, favoritesOnly: false, query: "").count, 1)
        let selected = try XCTUnwrap(guide.guideStreams(categoryID: value.categoryID, favoritesOnly: false, query: "").first)
        XCTAssertEqual(guide.playbackSource(for: selected).library.activeProfile?.id, f.second.id)
    }

    func testUnavailablePreferredProviderDoesNotHideTheOtherEnabledProvider() async throws {
        let f = try fixture(failFirst: true)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        XCTAssertEqual(guide.streams.count, 1)
        let channel = try XCTUnwrap(guide.streams.first)
        XCTAssertEqual(guide.providerName(for: channel), f.second.name)
        XCTAssertEqual(guide.playbackURLs(for: channel).first?.host, "second.invalid")
        XCTAssertNotNil(f.root.providerProblems[f.first.id])
        XCTAssertNil(f.root.providerProblems[f.second.id])
        XCTAssertEqual(f.root.activeProfile?.id, f.first.id)
        XCTAssertEqual(f.root.enabledProfiles.count, 2)
    }

    func testProviderDisplayNameIsNeverUsedAsSportsCategoryEvidence() {
        let now = Date()
        let game = SportsGame(id: "brand-is-not-category", league: .nba, start: now.addingTimeInterval(-600),
            awayTeam: "Orlando Magic", homeTeam: "Miami Heat", awayAbbreviation: "ORL", homeAbbreviation: "MIA",
            awayLogo: "", homeLogo: "", awayScore: "1", homeScore: "2", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Live", state: "in", broadcast: "ABC", eventName: nil)
        let channel = XtreamStream(num: 1, name: "NBA Orlando Magic at Miami Heat", streamType: "live", streamID: -7,
            streamIcon: nil, epgChannelID: nil, categoryID: "qualified")
        let category = XtreamCategory(categoryID: "qualified", categoryName: "Movies News VOD · Sports", sourceCategoryName: "Sports")
        XCTAssertEqual(SportsLibrary.matchingEventChannels(for: game, candidates: [channel], programs: [:],
            categories: [category], now: now).map(\.id), [-7])
    }

    func testMetadataRefreshFailureKeepsExistingChannelIdentityAndPlaybackURLs() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        let first = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.first.id })
        let second = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.second.id })
        let urls = guide.playbackURLs(for: first)
        let native = guide.playbackSource(for: second).library
        let data = MobileProviderSnapshot(categories: native.categories, streams: native.streams,
            programs: native.programsByChannel, fetchedAt: Date())
        let failedID = f.first.id
        let refresh = MobileProviderCatalog { profile, _ in
            if profile.id == failedID { throw URLError(.timedOut) }
            return data
        }
        let updated = await f.root.combinedGuide(catalog: refresh)
        XCTAssertEqual(updated.stream(withID: first.id), first)
        XCTAssertEqual(updated.playbackURLs(for: first), urls, "A metadata error must not replace or close a working provider stream")
        XCTAssertNotNil(updated.stream(withID: second.id))
        XCTAssertNotNil(f.root.providerProblems[f.first.id])
        XCTAssertFalse(updated.playbackSource(for: first).library.automaticMatchingReady, "Retire automatic event evidence until the provider validates again")
        XCTAssertEqual(f.root.activeProfile?.id, f.first.id)
    }

    func testExistingTeamAndSettingsActionsStayInSyncWithTheCombinedCatalog() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let guide = await f.root.combinedGuide(catalog: f.catalog)
        let a = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.first.id })
        let b = try XCTUnwrap(guide.streams.first { guide.playbackSource(for: $0).library.activeProfile?.id == f.second.id })
        let firstKey = TeamChannelKey(league: "NFL", identity: "BUF")
        let secondKey = TeamChannelKey(league: "NFL", identity: "KC")
        let team = FollowedTeam(key: firstKey, name: "Buffalo Bills", abbreviation: "BUF", logo: "")
        guide.toggleFollow(team)
        XCTAssertTrue(f.root.isFollowing(firstKey))
        XCTAssertTrue(guide.isFollowing(firstKey))
        f.root.unfollow(firstKey)
        XCTAssertFalse(guide.isFollowing(firstKey))
        guide.savePreference(a, for: firstKey, teamName: "Buffalo Bills")
        guide.savePreference(b, for: secondKey, teamName: "Kansas City Chiefs")
        guide.recordRecentChannel(a); guide.recordRecentChannel(b)
        f.root.removePreference(for: firstKey)
        f.root.clearRecentChannels()
        _ = await f.root.combinedGuide(catalog: f.catalog)
        XCTAssertNil(guide.teamPreferences.preference(for: firstKey))
        XCTAssertEqual(guide.teamPreferences.preference(for: secondKey)?.streamID, b.id)
        XCTAssertFalse(guide.recentStreams.contains { $0.id == a.id })
        XCTAssertEqual(guide.recentStreams.first?.id, b.id)
        XCTAssertEqual(f.root.activeProfile?.id, f.first.id)
    }

    func testFirstCombinedGuidePreservesTheExistingNativeFavoriteAndRecentOrder() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        f.defaults.set([8, 7], forKey: "NullSports.favoriteStreams.\(f.first.id)")
        f.defaults.set([8, 7], forKey: "NullSports.recentChannels.\(f.first.id)")
        let first = try await f.catalog.snapshot(for: f.first, secret: "first-test-secret")
        let second = try await f.catalog.snapshot(for: f.second, secret: "second-test-secret")
        let snapshots = [f.first.id: first, f.second.id: second]
        let catalog = MobileProviderCatalog { profile, _ in
            guard let original = snapshots[profile.id] else { throw URLError(.badServerResponse) }
            let extra = XtreamStream(num: 2, name: "Second native channel", streamType: "live", streamID: 8,
                streamIcon: nil, epgChannelID: nil, categoryID: "same-category")
            return MobileProviderSnapshot(categories: original.categories, streams: original.streams + [extra],
                programs: original.programs, fetchedAt: original.fetchedAt)
        }
        let guide = await f.root.combinedGuide(catalog: catalog)
        let favorites = guide.favoriteStreamOrder.compactMap { guide.stream(withID: $0) }
        XCTAssertEqual(favorites.map { guide.playbackSource(for: $0).stream.id }, [8, 7])
        XCTAssertEqual(guide.recentStreams.map { guide.playbackSource(for: $0).stream.id }, [8, 7])
        XCTAssertTrue(favorites.allSatisfy { guide.playbackSource(for: $0).library.activeProfile?.id == f.first.id })
    }
}

private final class ConcurrentProviderVault {
    var values: [UUID: String]
    init(values: [UUID: String]) { self.values = values }
    var store: ProviderCredentialStore {
        ProviderCredentialStore(password: { self.values[$0] }, save: { self.values[$1] = $0 }, delete: { self.values[$0] = nil })
    }
}

private actor ConcurrentProviderGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        let ready = waiting; waiting = []
        for continuation in ready { continuation.resume() }
    }
}
