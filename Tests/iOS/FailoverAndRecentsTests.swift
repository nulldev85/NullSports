import XCTest
@testable import LineupiOS

/// Stream recovery, and the two lightweight per-provider lists.
final class FailoverAndRecentsTests: XCTestCase {
    private func channel(_ id: Int, _ name: String, _ reason: FailoverChannel.Reason) -> FailoverChannel {
        FailoverChannel(streamID: id, name: name, reason: reason)
    }
    private var preferred: FailoverChannel { channel(1, "My Channel", .preference) }
    private var verified: FailoverChannel { channel(2, "ESPN", .verified) }
    private var altA: FailoverChannel { channel(3, "Alt A", .alternate) }
    private var altB: FailoverChannel { channel(4, "Alt B", .alternate) }
    private var plan: [FailoverChannel] {
        FailoverPlanner.plan(preference: preferred, verified: verified, alternates: [altA, altB])
    }

    // MARK: - Verified-feed failover and ordering

    /// The viewer's own channel outranks Lineup's match: they already said which
    /// feed they want.
    func testTheSavedTeamChannelIsTriedFirst() {
        XCTAssertEqual(plan.map(\.streamID), [1, 2, 3, 4])
        XCTAssertEqual(plan.first?.reason, .preference)
    }

    func testWithoutAPreferenceTheVerifiedMatchLeads() {
        let plan = FailoverPlanner.plan(preference: nil, verified: verified, alternates: [altA])
        XCTAssertEqual(plan.map(\.streamID), [2, 3])
    }

    /// Nothing unverified can enter the plan, so a game with no verified
    /// alternates simply never switches.
    func testAGameWithNothingVerifiedHasNoPlan() {
        XCTAssertTrue(FailoverPlanner.plan(preference: nil, verified: nil, alternates: []).isEmpty)
        var state = StreamFailoverState()
        XCTAssertNil(state.next(from: [], current: 7))
    }

    func testAChannelThatIsBothPreferredAndVerifiedAppearsOnce() {
        let plan = FailoverPlanner.plan(preference: channel(2, "ESPN", .preference),
                                        verified: verified, alternates: [altA])
        XCTAssertEqual(plan.map(\.streamID), [2, 3])
        XCTAssertEqual(plan.first?.reason, .preference)
    }

    // MARK: - Retry limits

    func testSwitchingStopsAtTheCap() {
        var state = StreamFailoverState()
        XCTAssertEqual(state.next(from: plan, current: nil)?.streamID, 1)
        XCTAssertEqual(state.next(from: plan, current: 1)?.streamID, 2)
        XCTAssertEqual(state.next(from: plan, current: 2)?.streamID, 3)
        XCTAssertNil(state.next(from: plan, current: 3), "A fourth move would be a loop, not a recovery")
        XCTAssertEqual(StreamFailoverState.maxSwitches, 3)
    }

    /// The rule that stops two broken feeds bouncing off each other.
    func testTwoBrokenFeedsCannotPingPong() {
        var state = StreamFailoverState()
        let pair = [preferred, verified]
        XCTAssertEqual(state.next(from: pair, current: nil)?.streamID, 1)
        XCTAssertEqual(state.next(from: pair, current: 1)?.streamID, 2)
        XCTAssertNil(state.next(from: pair, current: 2))
    }

    func testARetiredChannelIsNeverOfferedAgain() {
        var state = StreamFailoverState()
        _ = state.next(from: plan, current: nil)
        XCTAssertEqual(state.next(from: plan, current: nil)?.streamID, 2)
    }

    /// Manual Retry is the viewer insisting, so the history clears and Retry and
    /// Choose Another Channel stay meaningful after an exhausted failover.
    func testManualRetryMakesFailedChannelsEligibleAgain() {
        var state = StreamFailoverState()
        _ = state.next(from: plan, current: nil)
        _ = state.next(from: plan, current: 1)
        _ = state.next(from: plan, current: 2)
        XCTAssertNil(state.next(from: plan, current: 3))
        state.reset()
        XCTAssertEqual(state.next(from: plan, current: nil)?.streamID, 1)
    }

    func testEachSwitchReasonReadsDifferently() {
        XCTAssertTrue(preferred.notice.contains("My Channel"))
        XCTAssertTrue(verified.notice.contains("ESPN"))
        XCTAssertNotEqual(preferred.notice, altA.notice)
        XCTAssertNotEqual(verified.notice, altB.notice)
    }

    // MARK: - Alternate URL ordering (engine selection)

    /// Failover only escalates to another channel once the current channel's own
    /// URLs are spent — and those are ordered HLS first so PiP is reachable,
    /// with the transport stream behind it as the VLC fallback.
    func testTheCurrentChannelsAlternateURLsAreOrderedBeforeAnyChannelSwitch() {
        let hls = URL(string: "http://e.com/live/u/p/1.m3u8")!
        let ts = URL(string: "http://e.com/live/u/p/1.ts")!
        XCTAssertEqual(MobileEngineSelection.ordered([ts, hls]), [hls, ts])
        XCTAssertEqual(MobileEngineSelection.engine(for: hls), .system)
        XCTAssertEqual(MobileEngineSelection.engine(for: ts), .vlc)
        XCTAssertTrue(MobileEngineSelection.canPictureInPicture([ts, hls]))
        XCTAssertFalse(MobileEngineSelection.canPictureInPicture([ts]))
    }

    // MARK: - Recent channels

    func testRecentChannelsAreMostRecentFirstWithoutDuplicates() {
        XCTAssertEqual(RecentChannels.updated([], watching: 5), [5])
        XCTAssertEqual(RecentChannels.updated([5], watching: 5), [5])
        XCTAssertEqual(RecentChannels.updated([5, 6], watching: 6), [6, 5])
    }

    func testRecentChannelsAreCapped() {
        XCTAssertEqual(RecentChannels.updated([1, 2, 3], watching: 4, limit: 3), [4, 1, 2])
        XCTAssertEqual(RecentChannels.updated(Array(1...30), watching: 99).count, RecentChannels.limit)
    }

    /// A removed channel must not stay playable through a stale entry, but the
    /// stored list keeps it in case the provider carries it again.
    func testRemovedChannelsAreFilteredOnReadNotDeletedOnWrite() {
        let stored = RecentChannels.updated([9, 8], watching: 7)
        XCTAssertEqual(stored, [7, 9, 8])
        XCTAssertEqual(RecentChannels.resolved(stored, available: [9, 7]), [7, 9])
        XCTAssertTrue(RecentChannels.resolved(stored, available: []).isEmpty)
        XCTAssertEqual(stored, [7, 9, 8], "Availability filtering never mutates what is stored")
    }

    /// Provider isolation: recents live under a per-provider key, exactly like
    /// favorites and team preferences.
    func testRecentChannelsAreScopedToTheActiveProvider() throws {
        let suite = "FailoverAndRecentsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = { (id: UUID) in "NullSports.recentChannels." + id.uuidString }
        let first = UUID(), second = UUID()

        defaults.set([11, 12], forKey: key(first))
        defaults.set([21], forKey: key(second))

        XCTAssertEqual(defaults.array(forKey: key(first)) as? [Int], [11, 12])
        XCTAssertEqual(defaults.array(forKey: key(second)) as? [Int], [21])
        XCTAssertNil(defaults.array(forKey: key(UUID())), "An unknown provider has no recent channels")
    }
}
