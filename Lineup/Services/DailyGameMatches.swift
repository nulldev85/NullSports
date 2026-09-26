import Foundation

enum DailyCachePolicy {
    static func hasCompleteIndex(savedLeagues: Set<String>, expectedLeagues: Set<String>) -> Bool {
        !expectedLeagues.isEmpty && savedLeagues == expectedLeagues
    }

    static func canReuseMatch(savedSignature: String?, currentSignature: String, hasMatch: Bool) -> Bool {
        hasMatch && savedSignature == currentSignature
    }

    // A provider can recycle a numeric stream ID for a different event. Cached
    // guide evidence is only safe to reuse after the fresh channel response says
    // that the ID still describes the same named EPG slot.
    static func isSameChannelSlot(cachedID: Int, freshID: Int, cachedName: String, freshName: String,
                                  cachedEPG: String?, freshEPG: String?) -> Bool {
        cachedID == freshID && cachedName == freshName && cachedEPG == freshEPG
    }

    // Shared by every generation-tokened background rebuild (professional index,
    // game/channel matching). A rebuild that finishes after a newer one has already
    // started, or after the active profile has changed, must not publish its result.
    static func shouldApplyRebuild(resultGeneration: UUID, currentGeneration: UUID,
                                    resultProfileID: UUID?, currentProfileID: UUID?) -> Bool {
        resultGeneration == currentGeneration && resultProfileID == currentProfileID
    }

    static func isCurrent(savedAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        savedAt <= now && calendar.isDate(savedAt, inSameDayAs: now)
    }

    // Yesterday's snapshot can contain games prepared for today. The caller
    // filters its schedule to today's slate, and identities limit restored
    // matches to games that are still present in that slate.
    static func includesTodayOrYesterday(savedAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard savedAt <= now else { return false }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return savedAt >= yesterday
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
        guard DailyCachePolicy.includesTodayOrYesterday(savedAt: savedAt, now: now, calendar: calendar) else { return [:] }
        let availableChannels = Set(available)
        return channels.filter { id, channel in
            guard let identity = identities[id], let currentIdentity = current[id] else { return false }
            return identity == currentIdentity && availableChannels.contains(channel)
        }
    }
}
