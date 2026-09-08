import Foundation

@main
enum DailyGameMatchesChecks {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
        let savedAt = day.addingTimeInterval(10 * 3600)
        let reopen = day.addingTimeInterval(18 * 3600)
        let leagues = ["nfl", "nba", "nhl", "mlb", "ncaaf"]
        let identities = Dictionary(uniqueKeysWithValues: leagues.map { ($0, [$0, "away", "home", "ESPN", "kickoff"]) })
        let channels = Dictionary(uniqueKeysWithValues: leagues.map { ($0, "channel-" + $0) })
        let saved = DailyGameMatches(savedAt: savedAt, identities: identities, channels: channels)
        let data = try JSONEncoder().encode(saved)
        let restored = try JSONDecoder().decode(DailyGameMatches<String>.self, from: data)
        func matches(_ inputs: [String: [String]]? = nil, available: [String]? = nil,
                     now: Date? = nil) -> [String: String] {
            restored.restore(identities: inputs ?? identities, available: available ?? Array(channels.values), now: now ?? reopen, calendar: calendar)
        }
        precondition(matches() == channels, "Every league survives a disk round trip and same-day relaunch")
        precondition(matches(now: day.addingTimeInterval(24 * 3600)).isEmpty, "Midnight expires all yesterday's matches")
        precondition(matches(now: savedAt.addingTimeInterval(-1)).isEmpty, "Clock rollback rejects future cache")
        precondition(matches(available: []).isEmpty, "Another profile's library cannot restore unavailable channels")
        var updated = identities
        updated["mlb"] = ["mlb", "away", "home", "FOX", "kickoff"]
        precondition(matches(updated)["mlb"] == nil, "Changed broadcaster invalidates a saved match")
        precondition(matches(updated)["nfl"] == channels["nfl"], "One changed game does not invalidate other leagues")
        updated = identities
        updated.removeValue(forKey: "ncaaf")
        precondition(matches(updated)["ncaaf"] == nil, "Finished or removed game is not restored")
        updated = identities
        updated["nhl"] = ["nhl", "away", "home", "ESPN", "rescheduled kickoff"]
        precondition(matches(updated)["nhl"] == nil, "Rescheduling invalidates a saved match")
        precondition(matches(available: channels.values.filter { $0 != "channel-nba" })["nba"] == nil, "Removed or renamed channel is not restored")
        precondition(!DailyCachePolicy.isCurrent(savedAt: day.addingTimeInterval(-1), now: day, calendar: calendar), "Yesterday's schedule expires even one second after saving")
        precondition(DailyCachePolicy.isCurrent(savedAt: savedAt, now: reopen, calendar: calendar), "Today's schedule stays available offline")
        precondition(!DailyCachePolicy.isCurrent(savedAt: savedAt, now: day.addingTimeInterval(48 * 3600), calendar: calendar), "Multi-day absence requires a new schedule")
        // Local midnight, not UTC midnight, controls expiry.
        precondition(DailyCachePolicy.isCurrent(savedAt: day.addingTimeInterval(16 * 3600), now: reopen, calendar: calendar), "UTC date rollover does not discard the local day's schedule")
        print("13 daily schedule and match persistence checks passed")
    }
}
