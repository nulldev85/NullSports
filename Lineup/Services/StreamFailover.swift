import Foundation

/// A channel Lineup is willing to move to when the current one stops working.
///
/// Every candidate has a reason, and the reasons are the whole safety story:
/// nothing reaches this list unless the viewer chose it or the same matcher that
/// authorizes normal playback verified it for *this* game. There is no
/// "something else on that network" fallback.
struct FailoverChannel: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        /// The viewer's saved channel for one of the teams.
        case preference
        /// Lineup's primary verified match for the game.
        case verified
        /// Another channel the same matcher also verified for this game.
        case alternate
    }

    let streamID: Int
    let name: String
    let reason: Reason

    /// What the brief on-screen notice says when Lineup moves here.
    var notice: String {
        switch reason {
        case .preference: return "Switched to your channel for this game: \(name)"
        case .verified: return "Switched to \(name)"
        case .alternate: return "Switched to another feed: \(name)"
        }
    }
}

enum FailoverPlanner {
    /// Orders the channels worth trying for one game, best first.
    ///
    /// A saved preference outranks Lineup's own match — the viewer already said
    /// which feed they want — and duplicates collapse to their highest-ranked
    /// reason so a channel that is both preferred and verified is offered once.
    static func plan(preference: FailoverChannel?,
                     verified: FailoverChannel?,
                     alternates: [FailoverChannel]) -> [FailoverChannel] {
        var seen = Set<Int>()
        var ordered: [FailoverChannel] = []
        for channel in [preference, verified].compactMap({ $0 }) + alternates {
            guard seen.insert(channel.streamID).inserted else { continue }
            ordered.append(channel)
        }
        return ordered
    }
}

/// Tracks what has already been tried, so recovery cannot loop.
///
/// Two separate limits. A channel is retired the moment it fails, which stops
/// Lineup bouncing between two broken feeds; and the number of moves is capped
/// outright, so a game whose every listed channel is down ends on the error
/// state — with Retry and Choose Another Channel — instead of cycling forever.
struct StreamFailoverState: Equatable, Sendable {
    /// Deliberately small. Past three moves the problem is the provider or the
    /// connection, and further switching only delays telling the viewer.
    static let maxSwitches = 3

    private(set) var switches = 0
    private(set) var retired: Set<Int> = []

    init() {}

    /// Marks a channel as not worth returning to for this playback session.
    mutating func retire(_ streamID: Int?) {
        guard let streamID else { return }
        retired.insert(streamID)
    }

    var canSwitch: Bool { switches < Self.maxSwitches }

    /// The next channel to move to, or nil when recovery should stop and show
    /// the error state. Retires the channel it hands back: one attempt each.
    mutating func next(from plan: [FailoverChannel], current: Int?) -> FailoverChannel? {
        retire(current)
        guard canSwitch else { return nil }
        guard let next = plan.first(where: { !retired.contains($0.streamID) }) else { return nil }
        switches += 1
        retired.insert(next.streamID)
        return next
    }

    /// A manual Retry is the viewer insisting; it clears the history so the
    /// channels that failed earlier are eligible again.
    mutating func reset() {
        switches = 0
        retired.removeAll()
    }
}
