import XCTest
@testable import LineupiOS

/// Preferred channels by team. The decision itself is pure, so these cover it
/// directly rather than driving the Live screen.
final class TeamPreferenceTests: XCTestCase {
    private let game = TeamChannelGame(league: "nfl",
                                       homeTeam: "Kansas City Chiefs", homeAbbreviation: "KC",
                                       awayTeam: "Buffalo Bills", awayAbbreviation: "BUF")
    private let espn = 101, fox = 202, regional = 303, verified = 999
    private var carried: Set<Int> { [espn, fox, regional, verified] }

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

    // MARK: - Verification, not mere availability

    /// The distinction the whole type turns on. `available` means the provider
    /// still carries the channel; `verified` means evidence says it is carrying
    /// *this* game. A regional network is available all season and verified for
    /// only some of the schedule.
    private func resolve(_ store: TeamChannelPreferences, ready: Bool = true,
                         available: Set<Int>? = nil, verified: Set<Int> = [],
                         match: Int? = nil) -> PreferredChannel {
        store.resolve(game, matchingReady: ready,
                      availableStreamIDs: available ?? carried,
                      verifiedStreamIDs: verified, verifiedStreamID: match)
    }

    private var savedHome: TeamChannelPreferences {
        store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs"))])
    }

    /// 1. Preferred channel exists and carries the game.
    func testAVerifiedPreferencePlaysAutomatically() {
        XCTAssertEqual(resolve(savedHome, verified: [espn], match: espn),
                       .play(streamID: espn, source: .homePreference))
    }

    /// 2. Preferred channel exists but is not carrying this game — the bug this
    /// change fixes. Marquee is in the lineup; tonight's game is not on it.
    func testAnAvailableButUnverifiedPreferenceYieldsToTheVerifiedFeed() {
        let saved = savedHome
        XCTAssertEqual(resolve(saved, verified: [fox], match: fox),
                       .play(streamID: fox, source: .verified))
        XCTAssertEqual(saved.preference(for: game.homeKey)?.streamID, espn,
                       "Yielding for one game must not delete the preference")
    }

    /// 3. Matching still running: nothing is verified yet, so nothing plays.
    /// A preference must never bypass the evidence normal playback requires.
    func testAnUnverifiedPreferenceDoesNotPlayWhileMatchingRuns() {
        XCTAssertEqual(resolve(savedHome, ready: false, verified: []), .syncing)
        XCTAssertEqual(resolve(savedHome, ready: false, verified: [espn], match: espn), .syncing,
                       "An unsettled index outranks even a channel that looks verified")
        XCTAssertEqual(resolve(TeamChannelPreferences(), ready: false), .syncing)
    }

    /// 4. Preferred channel gone from the lineup entirely.
    func testAMissingPreferenceFallsBackAndStaysSaved() {
        let saved = savedHome
        XCTAssertEqual(resolve(saved, available: [fox], verified: [fox], match: fox),
                       .play(streamID: fox, source: .verified))
        XCTAssertNotNil(saved.preference(for: game.homeKey))
    }

    /// 5. Neither the preference nor anything else is verified.
    func testNothingVerifiedOpensThePicker() {
        XCTAssertEqual(resolve(savedHome, verified: []), .pick)
        XCTAssertEqual(resolve(TeamChannelPreferences(), verified: [], match: nil), .pick)
        // A match Lineup holds but the provider has dropped is not played.
        XCTAssertEqual(resolve(savedHome, available: [regional], verified: [], match: fox), .pick)
    }

    /// A verified preference stands on its own evidence and does not require
    /// Lineup to have produced a match of its own.
    func testAVerifiedPreferenceDoesNotNeedLineupsOwnMatch() {
        XCTAssertEqual(resolve(savedHome, verified: [espn], match: nil),
                       .play(streamID: espn, source: .homePreference))
    }

    // MARK: - Opposing teams

    /// 6. Both teams have a saved channel, only one is carrying the game. There
    /// is nothing to ask about, so no Which Feed dialog.
    func testOnlyOneVerifiedSidePlaysWithoutAConflict() {
        let both = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs")),
                          (game.awayKey, pref(fox, "FOX", "Buffalo Bills"))])
        XCTAssertEqual(resolve(both, verified: [fox], match: fox),
                       .play(streamID: fox, source: .awayPreference))
        XCTAssertEqual(resolve(both, verified: [espn], match: espn),
                       .play(streamID: espn, source: .homePreference))
    }

    /// 7. Both verified and disagreeing.
    func testTwoVerifiedDisagreeingPreferencesAskWhichFeed() {
        let both = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs")),
                          (game.awayKey, pref(fox, "FOX", "Buffalo Bills"))])
        XCTAssertEqual(resolve(both, verified: [espn, fox], match: espn),
                       .chooseFeed(home: TeamFeedOption(team: "Kansas City Chiefs", streamID: espn, channelName: "ESPN"),
                                   away: TeamFeedOption(team: "Buffalo Bills", streamID: fox, channelName: "FOX")))
    }

    func testTwoPreferencesNamingTheSameVerifiedChannelDoNotAsk() {
        let both = store([(game.homeKey, pref(espn, "ESPN", "Kansas City Chiefs")),
                          (game.awayKey, pref(espn, "ESPN", "Buffalo Bills"))])
        XCTAssertEqual(resolve(both, verified: [espn], match: espn),
                       .play(streamID: espn, source: .homePreference))
    }

    // MARK: - The exclusive-national case

    /// 9. Marquee is saved for the Cubs and the provider carries it, but
    /// tonight's game is exclusive to a national feed. The regional channel
    /// cannot be the answer, and must survive for the next game.
    func testAnExclusiveNationalGameCannotSelectTheRegionalPreference() {
        let marquee = regional, national = fox
        var cubs = TeamChannelPreferences()
        cubs.set(pref(marquee, "Marquee Sports Network", "Chicago Cubs"), for: game.homeKey)

        let outcome = resolve(cubs, available: [marquee, national], verified: [national], match: national)
        XCTAssertEqual(outcome, .play(streamID: national, source: .verified))
        if case let .play(id, _) = outcome {
            XCTAssertNotEqual(id, marquee, "The regional network is carried, but is not showing this game")
        }
        XCTAssertEqual(cubs.preference(for: game.homeKey)?.streamID, marquee,
                       "Marquee remains the Cubs preference for future games")
    }

    /// 8. The same rule governs recovery: an unverified saved channel never
    /// enters the failover plan, so a mid-game switch cannot land on it.
    func testAnUnverifiedPreferenceIsExcludedFromFailover() {
        // The library supplies `preference:` only when it is verified for the
        // game, so the unverified case reaches the planner as nil.
        let verifiedNational = FailoverChannel(streamID: fox, name: "FOX", reason: .verified)
        let plan = FailoverPlanner.plan(preference: nil, verified: verifiedNational, alternates: [])
        XCTAssertEqual(plan.map(\.streamID), [fox])
        XCTAssertFalse(plan.contains { $0.streamID == regional },
                       "A carried but unverified regional channel is not a failover target")

        var state = StreamFailoverState()
        XCTAssertEqual(state.next(from: plan, current: nil)?.streamID, fox)
        XCTAssertNil(state.next(from: plan, current: fox), "And there is nothing unverified to fall back to")
    }

    /// 10. College keeps its own, stricter evidence rules — the network a game
    /// is scheduled on is not proof a channel is carrying it. The preference
    /// path shares this rule rather than taking a name-only shortcut.
    func testCollegeMatchingStillRefusesNetworkOnlyEvidence() {
        let kickoff = Date()
        let matchup = CollegeChannelMatcher.Matchup(
            broadcast: "ESPN", away: "Ohio State", home: "Michigan",
            awayAbbreviation: "OSU", homeAbbreviation: "MICH",
            kickoff: kickoff, isLive: true, status: "In Progress")
        // A channel named for the network, carrying no listing for this game.
        XCTAssertNil(CollegeChannelMatcher.score(channel: "ESPN", listings: [], game: matchup,
                                                 now: kickoff, allowNetworkFallback: false),
                     "Network-only evidence cannot authorize college playback")
        XCTAssertNotNil(CollegeChannelMatcher.score(channel: "ESPN", listings: [], game: matchup,
                                                    now: kickoff, allowNetworkFallback: true),
                        "The fallback exists, but the playback path never enables it")
    }

    // MARK: - Provider scoping

    /// A channel identifier only means something inside the provider that issued
    /// it, so another provider must never inherit one.
    func testAnotherProviderStartsEmptyAndInheritsNothing() {
        let other = TeamChannelPreferences()
        XCTAssertNil(other.preference(for: game.homeKey))
        // Nothing saved here, and nothing of Lineup's own verified either.
        XCTAssertEqual(resolve(other, verified: []), .pick)
        // With a verified feed it uses that, never another provider's channel.
        XCTAssertEqual(resolve(other, verified: [espn], match: espn),
                       .play(streamID: espn, source: .verified))
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
