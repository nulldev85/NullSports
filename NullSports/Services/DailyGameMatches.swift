import Foundation

enum DailyCachePolicy {
    static func isCurrent(savedAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        savedAt <= now && calendar.isDate(savedAt, inSameDayAs: now)
    }
}

// The library stores this with the exact channel/guide snapshot used to match.
// Array identities preserve field boundaries without delimiter collisions.
struct DailyGameMatches<Channel: Codable & Hashable & Sendable>: Codable, Sendable {
    let savedAt: Date
    let identities: [String: [String]]
    let channels: [String: Channel]

    func restore(identities current: [String: [String]], available: [Channel],
                 now: Date, calendar: Calendar = .current) -> [String: Channel] {
        guard DailyCachePolicy.isCurrent(savedAt: savedAt, now: now, calendar: calendar) else { return [:] }
        let availableChannels = Set(available)
        return channels.filter { id, channel in
            guard let identity = identities[id], let currentIdentity = current[id] else { return false }
            return identity == currentIdentity && availableChannels.contains(channel)
        }
    }
}
