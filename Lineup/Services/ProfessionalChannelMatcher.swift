import Foundation

// A network or a mention elsewhere in the day's guide is not game evidence.
enum ProfessionalChannelMatcher {
    struct Listing: Sendable {
        let title: String
        let detail: String
        let start: Date
        let end: Date
    }

    struct Matchup: Sendable {
        let away: String
        let home: String
        let awayAbbreviation: String
        let homeAbbreviation: String
        let start: Date
        let isLive: Bool
    }

    /// A channel's listings with the normalizing already done.
    ///
    /// Normalizing is folding, lowercasing, splitting on every non-alphanumeric
    /// and rejoining -- five allocations and a full pass over the text. It used
    /// to happen inside the score, which is asked once per candidate channel
    /// per game: sixty-six games against five and a half thousand channels is
    /// three hundred thousand times, renormalizing the same channel name and
    /// the same team names over and over.
    struct PreparedListing: Sendable {
        let title: String
        let detail: String
        let text: String
        let start: Date
        let end: Date
    }

    /// A game's team names worked out once, rather than once per candidate.
    ///
    /// The aliases are stored already padded with spaces, because that is how
    /// they are compared: a word match is a search for " alias " inside
    /// " text ". Padding them at the point of comparison allocated two strings
    /// per phrase per call.
    struct PreparedGame: Sendable {
        let away: [String]
        let home: [String]
        let start: Date
        let isLive: Bool
    }

    /// A candidate channel, with everything that depends only on the channel
    /// already settled.
    ///
    /// Whether a channel is a replay, a highlights reel or a whip-around feed
    /// is a fact about the channel. It was being decided inside the score --
    /// twelve phrase comparisons, each allocating two strings -- and the score
    /// is asked once per game. Sixty-six times for the same answer, across
    /// five and a half thousand channels.
    struct PreparedChannel: Sendable {
        let padded: String
        let eligible: Bool
        let listings: [PreparedListing]
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func prepare(_ listings: [Listing]) -> [PreparedListing] {
        listings.map { listing in
            let title = normalize(listing.title)
            let detail = normalize(listing.detail)
            return PreparedListing(
                title: title, detail: detail,
                text: pad([title, detail].filter { !$0.isEmpty }.joined(separator: " ")),
                start: listing.start, end: listing.end)
        }
    }

    static func pad(_ text: String) -> String { " " + text + " " }

    private static let blockedPhrases = ["replay", "classic", "highlights", "radio", "audio", "preview"].map(pad)
    // Whip-around channels cut between games by design, so a guide entry
    // naming one game never describes what they are carrying minute to minute.
    private static let whipAroundPhrases = ["red zone", "redzone", "strike zone", "big inning", "whip around", "mix"].map(pad)

    static func prepare(channel: String, listings: [PreparedListing]) -> PreparedChannel {
        let padded = pad(normalize(channel))
        let eligible = !blockedPhrases.contains(where: padded.contains)
            && !whipAroundPhrases.contains(where: padded.contains)
        return PreparedChannel(padded: padded, eligible: eligible, listings: listings)
    }

    static func prepare(_ game: Matchup) -> PreparedGame {
        func aliases(_ name: String, _ abbreviation: String) -> [String] {
            let full = normalize(name)
            let nickname = full.split(separator: " ").last.map(String.init) ?? ""
            let lastTwo = full.split(separator: " ").suffix(2).joined(separator: " ")
            let short = normalize(abbreviation)
            return [full, lastTwo, nickname.count >= 4 ? nickname : "", short.count >= 2 ? short : ""].filter { !$0.isEmpty }
        }
        return PreparedGame(away: aliases(game.away, game.awayAbbreviation).map(pad),
                            home: aliases(game.home, game.homeAbbreviation).map(pad),
                            start: game.start, isLive: game.isLive)
    }

    /// Kept for callers scoring a single channel, where preparing costs nothing.
    static func score(channel: String, listings: [Listing], game: Matchup, now: Date) -> Int? {
        score(channel: prepare(channel: channel, listings: prepare(listings)),
              game: prepare(game), now: now)
    }

    /// Both sides are padded already, so a word match is a plain substring
    /// search with nothing allocated.
    static func score(channel: PreparedChannel, game: PreparedGame, now: Date) -> Int? {
        let away = game.away
        let home = game.home
        func matchup(_ padded: String) -> Bool {
            away.contains(where: padded.contains) && home.contains(where: padded.contains)
        }
        // Decided when the channel was prepared, not here.
        guard channel.eligible, !away.isEmpty, !home.isEmpty else { return nil }
        let name = channel.padded
        let point = game.isLive ? now : game.start
        let current = channel.listings.filter { $0.start <= point && point < $0.end }
        // Inspect each program independently: two unrelated listings cannot
        // combine into evidence for the requested matchup.
        let listingConfirms = current.contains { listing in
            listing.start <= game.start.addingTimeInterval(1800)
                && listing.end > game.start
                && !Self.blockedPhrases.contains(where: listing.text.contains)
                && matchup(listing.text)
        }
        // A named event feed is usable without guide data, but never overrides
        // a current listing identifying different coverage.
        let generic: Set<String> = ["", "live", "tba", "to be announced", "no information", "no guide information",
            "no program information", "baseball", "mlb baseball", "basketball", "nba basketball",
            "football", "nfl football", "hockey", "nhl hockey"]
        let guideSilent = current.allSatisfy { generic.contains($0.title) && $0.detail.isEmpty }

        // A channel named for this matchup exists to carry this one game, so it
        // outranks a national channel whose guide merely schedules it: the
        // national feed can cut away to another game without the guide changing.
        if matchup(name) && (listingConfirms || guideSilent) { return 400 }
        return listingConfirms ? 300 : nil
    }
}

/// NHL-specific ranking applied only after the ordinary matcher has proved a
/// channel is carrying the matchup. It never turns a network name into game
/// evidence by itself.
enum NHLChannelPolicy {
    static func adjustedScore(_ score: Int?, channel: String, broadcast: String) -> Int? {
        guard var score else { return nil }
        let channelName = ProfessionalChannelMatcher.normalize(channel)
        let words = Set(channelName.split(separator: " ").map(String.init))

        // DAZN's UK services do not carry these North American NHL game feeds.
        // Some providers attach the matchup's EPG to them anyway, which made a
        // dead/wrong channel beat the actual broadcaster. Exclude only the UK
        // variant; a manually selected exact-game channel remains authoritative.
        if words.contains("dazn") && words.contains("uk") { return nil }

        let named = ProfessionalChannelMatcher.normalize(broadcast)
        if named.contains("nhl net"), channelName.contains("nhl network")
            || channelName.contains("nhl net") {
            score += 80
        } else if sharesNamedNetwork(channel: channelName, broadcast: named) {
            score += 60
        } else if isEstablishedHockeyFeed(channelName) {
            score += 20
        }
        return score
    }

    private static func sharesNamedNetwork(channel: String, broadcast: String) -> Bool {
        let aliases = ["sportsnet", "tsn", "espn plus", "espn", "tnt", "tru tv", "abc"]
        return aliases.contains { broadcast.contains($0) && channel.contains($0) }
    }

    private static func isEstablishedHockeyFeed(_ channel: String) -> Bool {
        ["nhl network", "sportsnet", "tsn", "espn plus"].contains(where: channel.contains)
    }
}

/// RedZone is intentionally excluded from ordinary matchup matching above: a
/// whip-around feed is never the correct channel for one team game. Its own
/// schedule event can, however, select the dedicated channel by exact identity.
enum NFLRedZoneChannelMatcher {
    private static let blocked = ["replay", "classic", "highlights", "radio", "audio", "preview"]

    static func score(channel: String) -> Int? {
        let normalized = ProfessionalChannelMatcher.normalize(channel)
        let padded = ProfessionalChannelMatcher.pad(normalized)
        guard !blocked.contains(where: { padded.contains(ProfessionalChannelMatcher.pad($0)) }) else {
            return nil
        }
        let identifiesRedZone = padded.contains(" redzone ") || padded.contains(" red zone ")
        guard identifiesRedZone, padded.contains(" nfl ") else { return nil }
        return 500
    }
}
