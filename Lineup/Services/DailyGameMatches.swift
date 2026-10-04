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

    static func canCarryMatches(savedAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard savedAt <= now else { return false }
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
        return savedAt >= yesterday
    }
}

/// When the library's cache files are worth reading, asking about, or writing.
///
/// The library keeps three files per provider rather than one: the channel
/// list, the guide, and a small state file holding timestamps, today's matches
/// and the digests of what the server last sent. The split is what lets the
/// channels be read -- and drawn -- without the guide in front of them, and
/// what stops a new timestamp from rewriting a day of listings alongside it.
enum LibraryCachePolicy {
    /// What the channel file would contain, said in a few characters.
    ///
    /// Categories and channels are only ever assigned from a payload that
    /// carried a digest, and the index is a function of those and the guide,
    /// so these four answer "would writing it put back what is already there?"
    /// without encoding a megabyte to find out.
    static func channelsSignature(categoriesDigest: String?, streamsDigest: String?,
                                  guideDigest: String?, hasIndex: Bool) -> String {
        "\(categoriesDigest ?? "-")|\(streamsDigest ?? "-")|\(guideDigest ?? "-")|\(hasIndex)"
    }

    static func guideSignature(guideDigest: String?) -> String { guideDigest ?? "-" }

    /// Whether a file whose contents would be `signature` still needs writing.
    static func needsWriting(signature: String, lastWritten: String?) -> Bool {
        signature != lastWritten
    }

    /// The digest to send with a request, which is nil unless what it
    /// describes is actually in hand.
    ///
    /// A digest says "tell me only if this changed". Sent while holding
    /// nothing -- a cache file that went missing, one that would not decode --
    /// the answer "nothing changed" leaves the app empty with no way to ask
    /// again. Held data is what earns the right to ask the cheap question.
    static func digest(_ digest: String?, whenHolding hasData: Bool) -> String? {
        hasData ? digest : nil
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
        // Yesterday's pass already matched today's upcoming events. The current
        // identity set excludes finished games, and exact identities plus the
        // available channel list still guard every restored entry.
        guard DailyCachePolicy.canCarryMatches(savedAt: savedAt, now: now, calendar: calendar) else { return [:] }
        let availableChannels = Set(available)
        return channels.filter { id, channel in
            guard let identity = identities[id], let currentIdentity = current[id] else { return false }
            return identity == currentIdentity && availableChannels.contains(channel)
        }
    }
}
