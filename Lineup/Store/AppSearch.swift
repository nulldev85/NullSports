import Foundation

/// The four places the Search tab sorts what it finds into, in the order the
/// tab lists them.
enum AppSearchCategory: String, CaseIterable, Identifiable, Sendable {
    case movies, shows, live, vod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: "Movies"
        case .shows: "Shows"
        case .live: "Live TV"
        case .vod: "VOD"
        }
    }

    var symbol: String {
        switch self {
        case .movies: "film"
        case .shows: "tv"
        case .live: "dot.radiowaves.left.and.right"
        case .vod: "play.rectangle.on.rectangle"
        }
    }
}

/// Something the Search tab found, and where in the app it lives.
struct AppSearchHit: Identifiable, Sendable {
    enum Kind: Sendable {
        /// A film or a show on the media servers -- once, however many of
        /// them have it -- with the servers that do.
        case title(MediaItem, servers: [String])
        /// One of the IPTV provider's films or shows, with the provider's
        /// category for it.
        case vod(MediaItem, group: String?)
        /// A game, live or to come, and the channel it plays on.
        case game(SportsGame, channel: XtreamStream?)
        /// A live channel, with what is on it now.
        case channel(XtreamStream, now: CurrentProgram?, group: String?)
        /// A programme in the guide: its next airing on a channel, and how
        /// many more airings of it that channel has after that one.
        case airing(CurrentProgram, channel: XtreamStream, more: Int, group: String?)
    }

    let id: String
    let kind: Kind

    var category: AppSearchCategory {
        switch kind {
        case .title(let item, _): AppSearch.isShow(item) ? .shows : .movies
        case .vod: .vod
        case .game, .channel, .airing: .live
        }
    }
}

/// Everything one query found, by category.
struct AppSearchResults: Sendable {
    var movies: [AppSearchHit] = []
    var shows: [AppSearchHit] = []
    var live: [AppSearchHit] = []
    var vod: [AppSearchHit] = []

    func hits(in category: AppSearchCategory) -> [AppSearchHit] {
        switch category {
        case .movies: movies
        case .shows: shows
        case .live: live
        case .vod: vod
        }
    }

    var total: Int { movies.count + shows.count + live.count + vod.count }
}

/// One query across the whole app: the media servers' films and shows, the
/// live channels, the guide and the games, and the IPTV provider's VOD.
///
/// The matching here is plain and local, so it can run away from the main
/// thread on a copy of what the stores hold; the servers are asked by the
/// Library, which already knows how.
enum AppSearch {
    /// What the live side holds that a query is matched against, copied off
    /// the store so the matching can run on another thread.
    struct LiveSnapshot: Sendable {
        let channels: [XtreamStream]
        /// A channel category's name by its id.
        let groups: [String: String]
        /// The guide: each channel's listings by its guide id.
        let programs: [String: [CurrentProgram]]
        /// Every game the schedule holds, with the channel it was matched to.
        let games: [(game: SportsGame, channel: XtreamStream?)]
    }

    static let channelLimit = 40
    static let airingLimit = 80
    static let gameLimit = 30

    /// A show rather than a film, for the category a title is listed under.
    static func isShow(_ item: MediaItem) -> Bool {
        ["Series", "Season", "Episode"].contains(item.type)
    }

    /// The words of a query, each to be found somewhere in a name: "lakers
    /// celtics" finds "Boston Celtics at Los Angeles Lakers" as well as
    /// "Lakers Celtics".
    static func words(of query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Whether every word of the query is in the text, in any case and with or
    /// without accents.
    static func matches(_ text: String, _ words: [String]) -> Bool {
        !words.isEmpty && words.allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Games, then channels, then the guide: what is live in front of what is
    /// on later, and each in the order it is most likely wanted.
    static func live(_ query: String, in snapshot: LiveSnapshot, now: Date = Date()) -> [AppSearchHit] {
        let wanted = words(of: query)
        guard !wanted.isEmpty else { return [] }
        return games(wanted, snapshot, now: now) + channels(query, wanted, snapshot, now: now)
            + airings(wanted, snapshot, now: now)
    }

    /// Games still to be played or playing, by the teams, the event or the
    /// league: live first, then soonest.
    private static func games(_ words: [String], _ snapshot: LiveSnapshot, now: Date) -> [AppSearchHit] {
        let found = snapshot.games.filter { entry in
            let game = entry.game
            guard game.isLive || game.start > now else { return false }
            let text = [game.awayTeam, game.homeTeam, game.awayAbbreviation, game.homeAbbreviation,
                        game.eventName ?? "", game.league.shortName, game.league.fullName].joined(separator: " ")
            return matches(text, words)
        }
        return found.sorted { left, right in
            if left.game.isLive != right.game.isLive { return left.game.isLive }
            return left.game.start < right.game.start
        }
        .prefix(gameLimit)
        .map { AppSearchHit(id: "game|" + $0.game.id, kind: .game($0.game, channel: $0.channel)) }
    }

    /// Channels by name: a name that starts with the query first, then one
    /// that holds it as written, then one that holds its words.
    private static func channels(_ query: String, _ words: [String], _ snapshot: LiveSnapshot,
                                 now: Date) -> [AppSearchHit] {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func rank(_ name: String) -> Int {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            if name.range(of: phrase, options: options.union(.anchored)) != nil { return 0 }
            if name.range(of: phrase, options: options) != nil { return 1 }
            return 2
        }
        let found = snapshot.channels.filter { channel in
            !isRadio(channel) && matches(channel.name, words)
        }
        return found.map { (channel: $0, rank: rank($0.name)) }
            .sorted { left, right in
                if left.rank != right.rank { return left.rank < right.rank }
                return left.channel.name.localizedStandardCompare(right.channel.name) == .orderedAscending
            }
            .prefix(channelLimit)
            .map { entry in
                let channel = entry.channel
                let current = channel.epgChannelID
                    .flatMap { snapshot.programs[$0] }?
                    .first { $0.start <= now && now < $0.end }
                return AppSearchHit(id: "channel|\(channel.streamID)",
                                    kind: .channel(channel, now: current, group: group(of: channel, in: snapshot)))
            }
    }

    /// The guide's listings by title, one hit per programme per channel: its
    /// airing now or next, and how many more that channel has after it.
    /// What is on now comes first, then what starts soonest.
    private static func airings(_ words: [String], _ snapshot: LiveSnapshot, now: Date) -> [AppSearchHit] {
        // A guide id can belong to several channels -- one in HD and one in
        // SD -- and its listings are shown once, on the first of them.
        var channelForGuide: [String: XtreamStream] = [:]
        for channel in snapshot.channels where !isRadio(channel) {
            guard let guide = channel.epgChannelID, !guide.isEmpty, channelForGuide[guide] == nil else { continue }
            channelForGuide[guide] = channel
        }
        struct Found {
            var first: CurrentProgram
            var more: Int
            let channel: XtreamStream
        }
        var found: [String: Found] = [:]
        // A title is checked once however many times it airs.
        var verdicts: [String: Bool] = [:]
        for (guide, listings) in snapshot.programs {
            guard let channel = channelForGuide[guide] else { continue }
            for program in listings where program.end > now {
                let title = program.title
                let hit: Bool
                if let known = verdicts[title] { hit = known } else {
                    hit = matches(title, words)
                    verdicts[title] = hit
                }
                guard hit else { continue }
                let key = guide + "|" + title.lowercased()
                if var existing = found[key] {
                    if program.start < existing.first.start { existing.first = program }
                    existing.more += 1
                    found[key] = existing
                } else {
                    found[key] = Found(first: program, more: 0, channel: channel)
                }
            }
        }
        return found.values
            .sorted { left, right in
                let leftLive = left.first.start <= now, rightLive = right.first.start <= now
                if leftLive != rightLive { return leftLive }
                if left.first.start != right.first.start { return left.first.start < right.first.start }
                return left.channel.name.localizedStandardCompare(right.channel.name) == .orderedAscending
            }
            .prefix(airingLimit)
            .map { entry in
                AppSearchHit(id: "airing|\(entry.channel.streamID)|\(entry.first.title)|\(entry.first.start.timeIntervalSince1970)",
                             kind: .airing(entry.first, channel: entry.channel, more: entry.more,
                                           group: group(of: entry.channel, in: snapshot)))
            }
    }

    private static func group(of channel: XtreamStream, in snapshot: LiveSnapshot) -> String? {
        channel.categoryID.flatMap { snapshot.groups[$0] }
    }

    private static func isRadio(_ channel: XtreamStream) -> Bool {
        let type = channel.streamType?.lowercased()
        return type == "radio_streams" || type == "radio"
    }

    /// The media servers' films and shows, each title once however many
    /// servers have it, naming every server that does, in the order the
    /// servers answered.
    static func titles(from groups: [MediaLibrary.SearchGroup]) -> [AppSearchHit] {
        var order: [String] = []
        var found: [String: (item: MediaItem, servers: [String])] = [:]
        var owner: [String: String] = [:]
        for group in groups {
            for item in group.items where !item.isProviderTitle {
                let keys = [item.libraryKey] + MediaTitleMatch.keys(of: item)
                if let existing = keys.lazy.compactMap({ owner[$0] }).first {
                    if found[existing]?.servers.contains(group.serverName) == false {
                        found[existing]?.servers.append(group.serverName)
                    }
                    for key in keys where owner[key] == nil { owner[key] = existing }
                    continue
                }
                let id = item.libraryKey
                order.append(id)
                found[id] = (item, [group.serverName])
                for key in keys { owner[key] = id }
            }
        }
        return order.compactMap { id in
            found[id].map { AppSearchHit(id: "title|" + id, kind: .title($0.item, servers: $0.servers)) }
        }
    }
}
