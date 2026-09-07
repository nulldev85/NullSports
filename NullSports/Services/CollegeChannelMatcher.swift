import Foundation

// Pure matching policy, shared with the standalone regression checks.
enum CollegeChannelMatcher {
    static func unambiguousChannel(_ channelIDs: [String]) -> Bool {
        !channelIDs.isEmpty && !channelIDs.contains("") && Set(channelIDs).count == 1
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "+", with: " plus ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func contains(_ text: String, phrase: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }

    static func networks(_ value: String) -> Set<String> {
        let text = normalized(value)
        guard !contains(text, phrase: "news"), !contains(text, phrase: "business") else { return [] }
        let aliases: [(String, [String])] = [
            ("espnplus", ["espn plus"]), ("espn2", ["espn2", "espn 2"]),
            ("espnu", ["espnu", "espn u"]), ("espn", ["espn"]),
            ("fs1", ["fs1", "fox sports 1"]), ("fs2", ["fs2", "fox sports 2"]),
            ("fox", ["fox"]), ("cbssn", ["cbssn", "cbs sports network"]),
            ("cbs", ["cbs"]), ("nbc", ["nbc"]), ("abc", ["abc"]),
            ("btn", ["btn", "big ten network"]), ("accn", ["accn", "acc network"]),
            ("secn", ["secn", "sec network"]), ("cw", ["cw"]),
            ("peacock", ["peacock"])
        ]
        // Consume specific names first so ESPN2/ESPN+ cannot also become ESPN.
        var remaining = " " + text + " "
        var result: Set<String> = []
        for (network, names) in aliases {
            for name in names where remaining.contains(" " + name + " ") {
                result.insert(network)
                remaining = remaining.replacingOccurrences(of: " " + name + " ", with: " ")
            }
        }
        return result
    }

    static func titleMatches(_ title: String, away: String, home: String) -> Bool {
        // Explicit school aliases only; never generic abbreviations or mascots.
        let aliases = [
            "washington state cougars": "washington state",
            "washington huskies": "washington"
        ]
        var text = normalized(title)
        let teams = [away, home].map { normalized($0) }
            .map { aliases[$0] ?? $0 }.sorted { $0.count > $1.count }
        for team in teams {
            guard !team.isEmpty, contains(text, phrase: team) else { return false }
            // Remove the longer school first: Washington State is not Washington.
            text = (" " + text + " ").replacingOccurrences(of: " " + team + " ", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return true
    }

    static func verifies(broadcast: String, channel: String, title: String,
                         away: String, home: String, kickoff: Date,
                         programStart: Date, programEnd: Date, now: Date, isLive: Bool) -> Bool {
        let expected = networks(broadcast)
        let actual = networks(channel)
        guard !expected.isEmpty, !actual.isEmpty, actual.isSubset(of: expected),
              programStart <= kickoff.addingTimeInterval(1800), programEnd > kickoff,
              !isLive || (programStart <= now && now < programEnd) else { return false }
        return titleMatches(title, away: away, home: home)
    }
}
