import XCTest
@testable import LineupiOS

/// Preferred channels by team. The decision itself is pure, so these cover it
/// directly rather than driving the Live screen.
final class TeamPreferenceTests: XCTestCase {
    private let game = TeamChannelGame(league: "nfl",
                                       homeTeam: "Kansas City Chiefs", homeAbbreviation: "KC",
                                       awayTeam: "Buffalo Bills", awayAbbreviation: "BUF")
    private let espn = 101, fox = 202, verified = 999
    private var carried: Set<Int> { [espn, fox, verified] }

    private func pref(_ id: Int, _ channel: String, _ team: String,
                      at seconds: TimeInterval = 0) -> TeamChannelPreference {
        TeamChannelPreference(streamID: id, channelName: channel, teamName: team,
                              savedAt: Date(timeIntervalSince1970: seconds))
    }

    private func store(_ pairs: [(TeamChannelKey, TeamChannelPreference)]) -> TeamChannelPreferences {
        var store = TeamChannelPreferences()
        for (key, preference) in pairs { store.set(preference, for: key) }
        return store
    }

    // MARK: - Persistence

    func testPreferencesSurviveAnEncodeDecodeRoundTrip() throws {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])
        let data = try JSONEncoder().encode(saved)
        let restored = try JSONDecoder().decode(TeamChannelPreferences.self, from: data)
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(restored.preference(for: game.homeKey)?.streamID, espn)
        XCTAssertEqual(restored.preference(for: game.homeKey)?.channelName, "ESPN")
    }

    /// Identifiers have to be the stable ones, or a feed that reformats a team
    /// name between seasons silently orphans the preference.
    func testTeamKeysIgnoreDisplayNameChanges() {
        XCTAssertEqual(TeamChannelKey(league: "nfl", abbreviation: "KC", name: "Kansas City Chiefs"),
                       TeamChannelKey(league: "nfl", abbreviation: "kc", name: "KC Chiefs"))
        XCTAssertEqual(game.homeKey.storageKey, "NFL|KC")
    }

    func testAKeyWithoutAnAbbreviationFallsBackToTheName() {
        let key = TeamChannelKey(league: "ufc", abbreviation: "", name: "Jon  Jones")
        XCTAssertEqual(key.storageKey, "UFC|JON JONES")
        XCTAssertTrue(key.isUsable)
        XCTAssertFalse(TeamChannelKey(league: "nfl", abbreviation: "", name: " ").isUsable)
    }

    // MARK: - Automatic use and syncing

    func testASavedAvailablePreferenceIsUsedWithoutAsking() {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: true, availableStreamIDs: carried,
                                     verifiedStreamID: verified),
                       .play(streamID: espn, source: .homePreference))
    }

    /// An incomplete index makes every game look unmatched, so a picker or a
    /// verified fallback built on it would be a guess presented as an answer.
    func testUnfinishedMatchingReportsSyncingAndNeverPicks() {
        XCTAssertEqual(TeamChannelPreferences().resolve(game, matchingReady: false,
                                                       availableStreamIDs: carried,
                                                       verifiedStreamID: verified), .syncing)
        XCTAssertEqual(TeamChannelPreferences().resolve(game, matchingReady: false,
                                                       availableStreamIDs: [], verifiedStreamID: nil), .syncing)
        // A preference whose channel is gone cannot answer either, so the
        // unfinished index still wins.
        let stale = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])
        XCTAssertEqual(stale.resolve(game, matchingReady: false, availableStreamIDs: [fox],
                                     verifiedStreamID: verified), .syncing)
    }

    /// Cache restoration: the channel list comes back from disk, the saved
    /// preference points into it, and playback starts without waiting for the
    /// network pass that re-verifies matching. This is the repeat-launch win.
    func testASavedPreferencePlaysFromRestoredCacheBeforeMatchingFinishes() {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: false, availableStreamIDs: carried,
                                     verifiedStreamID: nil),
                       .play(streamID: espn, source: .homePreference))
        // Opposing preferences still resolve the same way from cache.
        let both = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs")),
                          (game.awayKey, pref(fox, "FOX", "Buffalo Bills"))])
        XCTAssertEqual(both.resolve(game, matchingReady: false, availableStreamIDs: carried,
                                    verifiedStreamID: nil),
                       .chooseFeed(home: TeamFeedOption(team: "Kansas City Chiefs", streamID: espn, channelName: "ESPN"),
                                   away: TeamFeedOption(team: "Buffalo Bills", streamID: fox, channelName: "FOX")))
    }

    /// The behaviour change: with nothing saved, the viewer chooses even though
    /// Lineup has a verified match to recommend.
    func testWithoutAPreferenceTheViewerPicks() {
        XCTAssertEqual(TeamChannelPreferences().resolve(game, matchingReady: true,
                                                        availableStreamIDs: carried,
                                                        verifiedStreamID: verified), .pick)
    }

    // MARK: - Opposing teams

    func testOpposingPreferencesAskWhichFeed() {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs")),
                           (game.awayKey, pref(fox, "FOX", "Buffalo Bills"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: true, availableStreamIDs: carried,
                                     verifiedStreamID: verified),
                       .chooseFeed(home: TeamFeedOption(team: "Kansas City Chiefs", streamID: espn, channelName: "ESPN"),
                                   away: TeamFeedOption(team: "Buffalo Bills", streamID: fox, channelName: "FOX")))
    }

    func testAgreeingPreferencesDoNotAsk() {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs")),
                           (game.awayKey, pref(espn, "ESPN", "Buffalo Bills"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: true, availableStreamIDs: carried,
                                     verifiedStreamID: verified),
                       .play(streamID: espn, source: .homePreference))
    }

    func testTheAwayPreferenceAppliesWhenOnlyItExists() {
        let saved = store([(game.awayKey, pref(fox, "FOX", "Buffalo Bills"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: true, availableStreamIDs: carried,
                                     verifiedStreamID: verified),
                       .play(streamID: fox, source: .awayPreference))
    }

    // MARK: - Unavailable and removed channels

    func testAnUnavailableChannelFallsBackToTheVerifiedMatchAndKeepsThePreference() {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: true, availableStreamIDs: [fox, verified],
                                     verifiedStreamID: verified),
                       .play(streamID: verified, source: .verified))
        XCTAssertEqual(saved.preference(for: game.homeKey)?.streamID, espn,
                       "Falling back must never delete the preference")
    }

    /// A provider that drops the channel and has no match for the game leaves
    /// the viewer choosing, still without losing what was saved.
    func testARemovedChannelWithNoVerifiedMatchEndsAtThePicker() {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: true, availableStreamIDs: [fox],
                                     verifiedStreamID: nil), .pick)
        XCTAssertNotNil(saved.preference(for: game.homeKey))
    }

    /// `gameStreamCache` can outlive a channel-list refresh, so a verified
    /// match is not by itself proof that the provider still has the channel.
    func testAVerifiedMatchTheProviderNoLongerCarriesIsNotPlayed() {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: true, availableStreamIDs: [fox],
                                     verifiedStreamID: verified), .pick)
    }

    func testAConflictResolvesItselfWhenOneChannelIsRemoved() {
        let saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs")),
                           (game.awayKey, pref(fox, "FOX", "Buffalo Bills"))])
        XCTAssertEqual(saved.resolve(game, matchingReady: true, availableStreamIDs: [fox, verified],
                                     verifiedStreamID: verified),
                       .play(streamID: fox, source: .awayPreference))
    }

    // MARK: - Provider scoping

    /// A channel identifier only means something inside the provider that issued
    /// it, so another provider must never inherit one.
    func testAnotherProviderStartsEmptyAndInheritsNothing() {
        let other = TeamChannelPreferences()
        XCTAssertNil(other.preference(for: game.homeKey))
        XCTAssertEqual(other.resolve(game, matchingReady: true, availableStreamIDs: carried,
                                     verifiedStreamID: verified), .pick)
    }

    /// Provider scoping is enforced by the storage key. Two providers writing
    /// the same team must not collide.
    func testEachProviderKeepsItsOwnStoreUnderItsOwnKey() throws {
        let suite = "TeamPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let key = { (id: UUID) in "NullSports.teamChannelPreferences." + id.uuidString }

        defaults.set(try JSONEncoder().encode(store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])),
                     forKey: key(first))
        defaults.set(try JSONEncoder().encode(store([(game.homeKey, pref(fox, "FOX", "Kansas City Chiefs"))])),
                     forKey: key(second))

        let restoredFirst = try JSONDecoder().decode(TeamChannelPreferences.self,
                                                     from: XCTUnwrap(defaults.data(forKey: key(first))))
        let restoredSecond = try JSONDecoder().decode(TeamChannelPreferences.self,
                                                      from: XCTUnwrap(defaults.data(forKey: key(second))))
        XCTAssertEqual(restoredFirst.preference(for: game.homeKey)?.streamID, espn)
        XCTAssertEqual(restoredSecond.preference(for: game.homeKey)?.streamID, fox)
        XCTAssertNil(defaults.data(forKey: key(UUID())), "An unknown provider has no preferences at all")
    }

    // MARK: - Settings listing

    func testListingIsNewestFirstAndSupportsRemoval() {
        var saved = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs", at: 100)),
                           (game.awayKey, pref(fox, "FOX", "Buffalo Bills", at: 200))])
        let rows = saved.listed()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.preference.teamName, "Buffalo Bills")
        XCTAssertEqual(rows.first?.key.storageKey, "NFL|BUF")
        saved.remove(for: game.awayKey)
        XCTAssertNil(saved.preference(for: game.awayKey))
        XCTAssertNotNil(saved.preference(for: game.homeKey))
        saved.removeAll()
        XCTAssertTrue(saved.isEmpty)
    }
}
