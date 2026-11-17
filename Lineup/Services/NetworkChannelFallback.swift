import Foundation

/// The channels a playlist has for the network a game is on -- ESPN, FS1,
/// ESPN2 -- for when the guide does not name the game yet: a game hours or a
/// day away, or one the guide calls only "College Basketball".
///
/// The network comes from the schedule, which says who is broadcasting it;
/// the channels are the playlist's own feeds of that network. A feed is left
/// out when its guide says it is showing something else then, when its name
/// is another game's own event feed, when it is in another language, or when
/// it is radio, a replay or the news.
enum NetworkChannelFallback {
    /// Words that rule a feed out whatever network it names.
    private static let blocked = ["radio", "audio", "sirius", "podcast", "music", "news", "business",
                                  "replay", "classic", "highlights"].map { " " + $0 + " " }

    /// How many feeds of the network one playlist offers, at most: a playlist
    /// can carry the same network many times over, in every quality.
    static let limit = 6

    /// The game's networks, as channel names spell them.
    static func networks(of game: SportsGame) -> Set<String> {
        CollegeChannelMatcher.networks(game.broadcast)
    }

    static func channels(for game: SportsGame, streams: [XtreamStream], categories: [XtreamCategory],
                         programs: [String: [CurrentProgram]], excluding: Set<Int> = []) -> [LiveEventChannel] {
        let wanted = networks(of: game)
        guard !wanted.isEmpty, !game.isEvent || game.league.isRacing else { return [] }
        let groups = Dictionary(categories.map { ($0.id, $0.matchingName) }, uniquingKeysWith: { first, _ in first })
        let point = game.isLive ? Date() : game.start
        var found: [LiveEventChannel] = []
        for stream in streams where !excluding.contains(stream.id) {
            guard !["radio", "radio_streams", "movie", "series", "episode", "video", "vod"]
                    .contains(stream.streamType?.lowercased() ?? "") else { continue }
            let networks = CollegeChannelMatcher.networks(stream.name)
            guard !networks.isDisjoint(with: wanted) else { continue }
            let padded = " " + CollegeChannelMatcher.normalized(stream.name) + " "
            guard !blocked.contains(where: padded.contains),
                  // "ESPN+ 23: Wilson vs Delaware" is that game's own feed.
                  !EventChannelEvidence.namesMatchup(stream.name) else { continue }
            let category = groups[stream.categoryID ?? ""] ?? ""
            guard !ChannelLanguage.isForeign(name: stream.name, category: category) else { continue }
            let program = (programs[stream.epgChannelID ?? ""] ?? []).first { $0.start <= point && point < $0.end }
            if let program, !shows(program, game: game) { continue }
            found.append(LiveEventChannel(stream: stream, program: program, evidence: 0,
                                          quality: LiveChannelQuality(name: stream.name)))
        }
        // A feed whose guide shows the game's sport or sides then before one
        // with no guide, then the best quality the provider names.
        return Array(found.sorted { left, right in
            if (left.program != nil) != (right.program != nil) { return left.program != nil }
            return left.quality > right.quality
        }.prefix(limit))
    }

    /// Whether what the guide has on a feed then can be this game: a title
    /// naming its sides, or one naming no more than its sport.
    static func shows(_ program: CurrentProgram, game: SportsGame) -> Bool {
        if EventChannelEvidence.isGenericTitle(program.title, league: game.league.rawValue) { return true }
        let text = program.title + " " + program.detail
        return CollegeChannelMatcher.titleMatches(text, away: game.awayTeam, home: game.homeTeam,
                                                  awayAbbreviation: game.awayAbbreviation,
                                                  homeAbbreviation: game.homeAbbreviation)
    }
}
