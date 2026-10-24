import XCTest
@testable import LineupiOS

final class MobileProviderChannelTests: XCTestCase {
    private func game(state: String = "in") -> SportsGame {
        SportsGame(id: "provider-game", league: .nba, start: Date().addingTimeInterval(-1200),
            awayTeam: "Orlando Magic", homeTeam: "Miami Heat", awayAbbreviation: "ORL", homeAbbreviation: "MIA",
            awayLogo: "", homeLogo: "", awayScore: "70", homeScore: "65", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Live", state: state,
            broadcast: "ABC", eventName: nil)
    }

    private func snapshot(title: String = "NBA Basketball: Orlando Magic at Miami Heat",
                          fetchedAt: Date = Date()) -> MobileProviderSnapshot {
        let stream = XtreamStream(num: 7, name: "US: ABC Miami FHD", streamType: "live", streamID: 7,
            streamIcon: nil, epgChannelID: "same-epg-id", categoryID: "sports")
        let program = CurrentProgram(channelID: "same-epg-id", title: title, detail: "",
            start: Date().addingTimeInterval(-1800), end: Date().addingTimeInterval(6000))
        return MobileProviderSnapshot(categories: [.init(categoryID: "sports", categoryName: "Sports")],
            streams: [stream], programs: ["same-epg-id": [program]], fetchedAt: fetchedAt)
    }

    func testSameNumberAndEPGIDInTwoAccountsCannotBorrowAnotherAccountsGuide() throws {
        let first = XtreamProfile(name: "Provider One", serverURL: "https://one.invalid", username: "first")
        let second = XtreamProfile(name: "Provider Two", serverURL: "https://two.invalid", username: "second")
        let event = game()
        let matched = try XCTUnwrap(snapshot().matching(event, board: []).first)
        XCTAssertTrue(snapshot(title: "Boston Celtics at Chicago Bulls").matching(event, board: []).isEmpty)
        let feeds = [MobileProviderChannel(profile: first, channel: matched),
                     MobileProviderChannel(profile: second, channel: matched)]
        XCTAssertEqual(Set(feeds.map(\.id)).count, 2)
        let grouped = MobileProviderChannelSection.grouped(feeds)
        XCTAssertEqual(grouped.map(\.height), [1080])
        XCTAssertEqual(grouped[0].channels.map(\.profile.name), ["Provider One", "Provider Two"])
        let firstURL = try XCTUnwrap(XtreamClient(profile: first, password: "test-one").playbackURLs(for: matched.stream).first)
        let secondURL = try XCTUnwrap(XtreamClient(profile: second, password: "test-two").playbackURLs(for: matched.stream).first)
        XCTAssertEqual(firstURL.host, "one.invalid")
        XCTAssertEqual(secondURL.host, "two.invalid")
        XCTAssertEqual(firstURL.path, "/live/first/test-one/7.m3u8")
        XCTAssertEqual(secondURL.path, "/live/second/test-two/7.m3u8")
    }

    func testExpiredEvidenceAndRecycledStreamAreRejectedOnSelection() throws {
        let event = game(), data = snapshot()
        let profile = XtreamProfile(name: "Test", serverURL: "https://example.invalid", username: "test")
        let channel = try XCTUnwrap(data.matching(event, board: []).first)
        let choice = MobileProviderChannel(profile: profile, channel: channel)
        XCTAssertEqual(data.verifiedStream(choice, game: event, board: []), channel.stream)
        XCTAssertNil(snapshot(fetchedAt: Date().addingTimeInterval(-121)).verifiedStream(choice, game: event, board: []))
        XCTAssertNil(snapshot(title: "Boston Celtics at Chicago Bulls").verifiedStream(choice, game: event, board: []))
        XCTAssertNil(data.verifiedStream(choice, game: game(state: "post"), board: []))
    }

    func testCatalogCoalescesRequestsAndSeparatesIDsConnectionsAndSecretsButAllowsRename() async throws {
        let calls = CatalogCalls()
        let data = snapshot()
        let catalog = MobileProviderCatalog { _, _ in
            await calls.record()
            try await Task.sleep(for: .milliseconds(20))
            return data
        }
        let first = XtreamProfile(name: "Original", serverURL: "https://one.invalid", username: "one")
        async let one = catalog.snapshot(for: first, secret: "test-one")
        async let two = catalog.snapshot(for: first, secret: "test-one")
        _ = try await (one, two)
        var renamed = first
        renamed.name = "Renamed"
        _ = try await catalog.snapshot(for: renamed, secret: "test-one")
        let afterRename = await calls.count
        XCTAssertEqual(afterRename, 1)
        _ = try await catalog.snapshot(for: first, secret: "different-test-secret")
        var moved = first
        moved.serverURL = "https://two.invalid"
        _ = try await catalog.snapshot(for: moved, secret: "test-one")
        let other = XtreamProfile(name: first.name, serverURL: first.serverURL, username: first.username)
        _ = try await catalog.snapshot(for: other, secret: "test-one")
        let total = await calls.count
        XCTAssertEqual(total, 4)
    }

    func testFailedProviderDoesNotPoisonAnotherProviderOrCacheAnError() async throws {
        let calls = CatalogCalls(), data = snapshot()
        let failing = UUID()
        let catalog = MobileProviderCatalog { profile, _ in
            await calls.record()
            if profile.id == failing { throw URLError(.cannotConnectToHost) }
            return data
        }
        let bad = XtreamProfile(id: failing, name: "Offline", serverURL: "https://bad.invalid", username: "one")
        let good = XtreamProfile(name: "Working", serverURL: "https://good.invalid", username: "two")
        for _ in 0..<2 {
            do { _ = try await catalog.snapshot(for: bad, secret: "test"); XCTFail("Expected provider failure") }
            catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
            let loaded = try await catalog.snapshot(for: good, secret: "test")
            XCTAssertEqual(loaded.streams, data.streams)
        }
        let total = await calls.count
        XCTAssertEqual(total, 3, "Successful account cached; offline account can retry")
    }

    func testCatalogLimitsConcurrentProviderDownloadsAcrossOverlappingLookups() async throws {
        let calls = CatalogConcurrency(), data = snapshot()
        let catalog = MobileProviderCatalog { _, _ in
            await calls.begin()
            try await Task.sleep(for: .milliseconds(20))
            await calls.finish()
            return data
        }
        let profiles = (0..<6).map { XtreamProfile(name: "Provider \($0)", serverURL: "https://example.invalid", username: "\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { _ = try await catalog.snapshot(for: profile, secret: "test") }
            }
            try await group.waitForAll()
        }
        let peak = await calls.peak
        XCTAssertEqual(peak, 2)
        let completed = await calls.completed
        XCTAssertEqual(completed, 6)
    }

    @MainActor
    func testRemovedOrEditedProviderCannotActivateAnOldDisplayedChannel() async throws {
        let suite = "ProviderSelection.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = XtreamProfile(name: "First", serverURL: "https://one.invalid", username: "one")
        let removed = XtreamProfile(name: "Removed", serverURL: "https://two.invalid", username: "two")
        defaults.set(try JSONEncoder().encode([first]), forKey: "NullSports.profiles")
        defaults.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        let library = SportsLibrary(profileDefaults: defaults)
        let event = game()
        let channel = try XCTUnwrap(snapshot().matching(event, board: []).first)
        let result = await library.activateEventChannel(.init(profile: removed, channel: channel), for: event)
        XCTAssertNil(result)
        XCTAssertEqual(library.activeProfile, first)
        var renamed = first
        renamed.name = "New name"
        XCTAssertTrue(SportsLibrary.sameProviderConnection(first, renamed))
        renamed.username = "different-account"
        XCTAssertFalse(SportsLibrary.sameProviderConnection(first, renamed))
        renamed = first
        renamed.connectionKind = "m3u"
        XCTAssertFalse(SportsLibrary.sameProviderConnection(first, renamed))
    }

    @MainActor
    func testRenameSurvivesRelaunchWithoutChangingCredentialsActiveAccountOrProviderState() throws {
        let suite = "ProviderRename.\(UUID())"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let first = XtreamProfile(name: "My IPTV", serverURL: "https://example.invalid", username: "one")
        let second = XtreamProfile(name: "Second", serverURL: "https://example.invalid", username: "two")
        let vault = ProviderTestCredentials()
        try vault.store.save("rename-test-only", first.id)
        let writesBeforeRename = vault.writes
        store.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.profiles")
        store.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        store.set([7, 3], forKey: "NullSports.favoriteStreams.\(first.id)")
        store.set([99], forKey: "NullSports.recentChannels.\(second.id)")
        let library = SportsLibrary(profileDefaults: store, credentials: vault.store)
        XCTAssertTrue(library.renameProfile(id: first.id, name: "  Home Sports \n"))
        XCTAssertTrue(library.renameProfile(id: second.id, name: "Backup"))
        XCTAssertFalse(library.renameProfile(id: first.id, name: " \n"))
        XCTAssertFalse(library.renameProfile(id: UUID(), name: "Removed"))
        let restored = SportsLibrary(profileDefaults: store, credentials: vault.store)
        XCTAssertEqual(restored.activeProfile?.id, first.id)
        XCTAssertEqual(restored.activeProfile?.name, "Home Sports")
        XCTAssertEqual(restored.profiles[1].name, "Backup")
        XCTAssertEqual(restored.favoriteStreamOrder, [7, 3])
        XCTAssertEqual(restored.activeProfile?.serverURL, first.serverURL)
        XCTAssertEqual(restored.activeProfile?.username, first.username)
        XCTAssertEqual(vault.store.password(first.id), "rename-test-only")
        XCTAssertEqual(vault.writes, writesBeforeRename, "Renaming must not rewrite a credential")
        XCTAssertTrue(vault.deletions.isEmpty, "Renaming must never delete a saved credential")
        let stream = XtreamStream(num: 7, name: "Test", streamType: "live", streamID: 7,
            streamIcon: nil, epgChannelID: nil, categoryID: nil)
        let url = try XCTUnwrap(restored.playbackURLs(for: stream).first)
        XCTAssertEqual(url.host, "example.invalid")
        XCTAssertEqual(url.path, "/live/one/rename-test-only/7.m3u8", "Relaunched playback must still use the saved account credential")
        XCTAssertEqual(store.array(forKey: "NullSports.recentChannels.\(second.id)") as? [Int], [99])
    }
}

private actor CatalogCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class ProviderTestCredentials {
    private var passwords: [UUID: String] = [:]
    private(set) var writes: [UUID] = []
    private(set) var deletions: [UUID] = []
    var store: ProviderCredentialStore {
        ProviderCredentialStore(password: { self.passwords[$0] }, save: {
            self.passwords[$1] = $0; self.writes.append($1)
        }, delete: { self.passwords[$0] = nil; self.deletions.append($0) })
    }
}

private actor CatalogConcurrency {
    private var active = 0
    private(set) var peak = 0
    private(set) var completed = 0
    func begin() { active += 1; peak = max(peak, active) }
    func finish() { active -= 1; completed += 1 }
}
