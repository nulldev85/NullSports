import Foundation

@main
struct StreamFailoverChecks {
    static func main() {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }

        func channel(_ id: Int, _ name: String, _ reason: FailoverChannel.Reason) -> FailoverChannel {
            FailoverChannel(streamID: id, name: name, reason: reason)
        }
        let preferred = channel(1, "My Channel", .preference)
        let verified = channel(2, "ESPN", .verified)
        let altA = channel(3, "Alt A", .alternate)
        let altB = channel(4, "Alt B", .alternate)

        // Ordering ---------------------------------------------------------
        let plan = FailoverPlanner.plan(preference: preferred, verified: verified, alternates: [altA, altB])
        check(plan.map(\.streamID) == [1, 2, 3, 4], "Preference first, then verified, then alternates")
        check(FailoverPlanner.plan(preference: nil, verified: verified, alternates: [altA]).map(\.streamID) == [2, 3],
              "Without a preference the verified match leads")
        check(FailoverPlanner.plan(preference: nil, verified: nil, alternates: []).isEmpty,
              "A game with nothing verified has no plan at all")
        // A channel that is both preferred and verified appears once, ranked high.
        let same = FailoverPlanner.plan(preference: channel(2, "ESPN", .preference), verified: verified,
                                        alternates: [altA])
        check(same.map(\.streamID) == [2, 3], "Duplicates collapse")
        check(same[0].reason == .preference, "A duplicate keeps its highest-ranked reason")

        // Switching limits -------------------------------------------------
        var state = StreamFailoverState()
        check(state.next(from: plan, current: nil)?.streamID == 1, "The first move takes the best candidate")
        check(state.next(from: plan, current: 1)?.streamID == 2, "The next move skips what already failed")
        check(state.next(from: plan, current: 2)?.streamID == 3, "And the next")
        check(state.next(from: plan, current: 3) == nil, "Switching stops at the cap")
        check(StreamFailoverState.maxSwitches == 3, "The cap is deliberate, not incidental")

        // A channel is never returned to, even when it heads the plan again.
        var retiring = StreamFailoverState()
        _ = retiring.next(from: plan, current: nil)
        check(retiring.next(from: plan, current: nil)?.streamID == 2,
              "A retired channel is not offered a second time")

        // Two broken feeds cannot ping-pong.
        var pair = StreamFailoverState()
        let twoChannels = [preferred, verified]
        check(pair.next(from: twoChannels, current: nil)?.streamID == 1, "First of two")
        check(pair.next(from: twoChannels, current: 1)?.streamID == 2, "Second of two")
        check(pair.next(from: twoChannels, current: 2) == nil, "Then it gives up rather than cycling")

        // Manual retry is the viewer insisting: history clears.
        pair.reset()
        check(pair.next(from: twoChannels, current: nil)?.streamID == 1, "Retry makes failed channels eligible again")

        // An empty plan never switches, so plain channel playback is unaffected.
        var none = StreamFailoverState()
        check(none.next(from: [], current: 7) == nil, "No candidates means no switch")

        // Notices ----------------------------------------------------------
        check(preferred.notice.contains("My Channel"), "A notice names the channel")
        check(verified.notice.contains("ESPN"), "So does the verified one")
        check(preferred.notice != altA.notice, "Each reason reads differently")

        // Recent channels --------------------------------------------------
        check(RecentChannels.updated([], watching: 5) == [5], "The first watch starts the list")
        check(RecentChannels.updated([5], watching: 5) == [5], "Re-watching does not duplicate")
        check(RecentChannels.updated([5, 6], watching: 6) == [6, 5], "Re-watching moves to the front")
        check(RecentChannels.updated([1, 2, 3], watching: 4, limit: 3) == [4, 1, 2], "The list is capped")
        check(RecentChannels.updated([1], watching: 2, limit: 0).isEmpty, "A zero limit keeps nothing")
        check(RecentChannels.resolved([1, 2, 3], available: [1, 3]) == [1, 3],
              "Channels the provider dropped are not playable from the list")
        check(RecentChannels.resolved([1, 2], available: []).isEmpty, "An empty provider resolves to nothing")
        // Filtering on read, not on write: a channel that returns keeps its place.
        let stored = RecentChannels.updated([9, 8], watching: 7)
        check(RecentChannels.resolved(stored, available: [9, 7]) == [7, 9], "Order survives a gap")
        check(stored == [7, 9, 8], "The stored list itself is untouched by availability")

        print("Stream failover and recent channel checks passed")
    }
}
