import Foundation

/// A team, identified by something that survives a provider refresh.
///
/// Team *names* arrive from the schedule feed and change formatting between
/// seasons ("St. Louis" / "St Louis", "Ohio St." / "Ohio State"), so the league
/// plus the abbreviation is the stable pair. The abbreviation is empty for a few
/// feeds — UFC events, mostly — and there the normalized name is the best key
/// available, which is why the fallback exists rather than refusing a key.
struct TeamChannelKey: Hashable, Codable, Sendable {
    let league: String
    let team: String

    init(league: String, abbreviation: String, name: String) {
        self.league = league.uppercased()
        let abbreviation = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !abbreviation.isEmpty {
            team = abbreviation
        } else {
            team = name.uppercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    /// Flat enough to be a dictionary key in JSON. `|` cannot occur in a league
    /// raw value or an abbreviation, so the halves stay unambiguous.
    var storageKey: String { league + "|" + team }

    var isUsable: Bool { !team.isEmpty }
}

/// One saved choice. `streamID` is the provider's stable channel identifier;
/// the names ride along so Settings can still describe a preference whose
/// channel the provider has since dropped.
struct TeamChannelPreference: Codable, Equatable, Sendable {
    let streamID: Int
    let channelName: String
    let teamName: String
    let savedAt: Date

    init(streamID: Int, channelName: String, teamName: String, savedAt: Date = Date()) {
        self.streamID = streamID
        self.channelName = channelName
        self.teamName = teamName
        self.savedAt = savedAt
    }
}

/// The teams in one game, reduced to what preference resolution needs. Keeping
/// this free of `SportsGame` is what lets the whole decision be tested without
/// the app's models or a provider.
struct TeamChannelGame: Equatable, Sendable {
    let league: String
    let homeTeam: String
    let homeAbbreviation: String
    let awayTeam: String
    let awayAbbreviation: String

    var homeKey: TeamChannelKey {
        TeamChannelKey(league: league, abbreviation: homeAbbreviation, name: homeTeam)
    }
    var awayKey: TeamChannelKey {
        TeamChannelKey(league: league, abbreviation: awayAbbreviation, name: awayTeam)
    }
}

/// One side's usable preference, carrying what the "which feed?" prompt shows.
struct TeamFeedOption: Equatable, Sendable {
    let team: String
    let streamID: Int
    let channelName: String
}

/// What tapping a game should do.
enum PreferredChannel: Equatable, Sendable {
    /// Channel matching has not finished. Say so; never show a half-built picker.
    case syncing
    /// Open this channel without asking.
    case play(streamID: Int, source: Source)
    /// Both teams have a preference and they disagree. Ask which feed to use.
    case chooseFeed(home: TeamFeedOption, away: TeamFeedOption)
    /// Nothing saved that applies. Show "Select your preferred channel."
    case pick

    enum Source: Equatable, Sendable {
        /// A viewer manually chose this channel for this exact game.
        case gameSelection
        case homePreference
        case awayPreference
        /// Lineup's own match. Reached when a saved preference exists but its
        /// channel is gone — the preference is kept, not deleted.
        case verified
    }
}

/// One saved preference with the team it belongs to. A struct rather than a
/// tuple because SwiftUI addresses list rows by key path, which tuples do not
/// support.
struct TeamChannelEntry: Identifiable, Equatable, Sendable {
    let key: TeamChannelKey
    let preference: TeamChannelPreference
    var id: String { key.storageKey }
}

/// One side of a game a preference can be saved for.
struct TeamChannelSide: Identifiable, Equatable, Sendable {
    let key: TeamChannelKey
    let team: String
    let isHome: Bool
    var id: String { key.storageKey }
    /// Named so the choice reads the way it was asked for — "the home team" —
    /// while still saying which team that actually is.
    var role: String { isHome ? "home team" : "away team" }
}

/// A manual choice scoped to one exact scheduled game.
///
/// This is deliberately separate from a team preference. Choosing "Just this
/// game" must survive a schedule refresh and an app restart, but it must never
/// leak into the next game that either team plays. The schedule feed's game ID
/// supplies that boundary; the expiry keeps old events from accumulating when
/// a provider retains a long schedule history.
struct GameChannelSelection: Codable, Equatable, Sendable {
    let streamID: Int
    let channelName: String
    let expiresAt: Date

    init(streamID: Int, channelName: String, gameStart: Date,
         savedAt: Date = Date(), lifetime: TimeInterval = 12 * 60 * 60) {
        self.streamID = streamID
        self.channelName = channelName
        // A late manual selection still gets a full window, while a selection
        // made near first pitch remains valid through even a long event.
        expiresAt = max(gameStart.addingTimeInterval(lifetime),
                        savedAt.addingTimeInterval(lifetime))
    }
}

/// Provider-scoped working channels for individual games, chosen by the viewer
/// or confirmed after automatic failover.
struct GameChannelSelections: Codable, Equatable, Sendable {
    private(set) var entries: [String: GameChannelSelection]

    init(entries: [String: GameChannelSelection] = [:]) {
        self.entries = entries
    }

    func selection(for gameID: String, at date: Date = Date()) -> GameChannelSelection? {
        guard let selection = entries[gameID], selection.expiresAt > date else { return nil }
        return selection
    }

    mutating func set(_ selection: GameChannelSelection, for gameID: String) {
        guard !gameID.isEmpty else { return }
        entries[gameID] = selection
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    mutating func prune(at date: Date = Date()) {
        entries = entries.filter { $0.value.expiresAt > date }
    }
}

/// Every saved team preference for one provider.
///
/// Deliberately *not* merged across providers the way favorites are. A channel
/// identifier only means something inside the provider that issued it, so
/// carrying one into another provider's lineup would silently point a team at an
/// unrelated channel. Scoping is enforced by the caller keying storage on the
/// active profile; this type simply never reaches for another provider's data.
struct TeamChannelPreferences: Codable, Equatable, Sendable {
    private(set) var entries: [String: TeamChannelPreference]

    init(entries: [String: TeamChannelPreference] = [:]) {
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func preference(for key: TeamChannelKey) -> TeamChannelPreference? {
        entries[key.storageKey]
    }

    mutating func set(_ preference: TeamChannelPreference, for key: TeamChannelKey) {
        guard key.isUsable else { return }
        entries[key.storageKey] = preference
    }

    mutating func remove(for key: TeamChannelKey) {
        entries.removeValue(forKey: key.storageKey)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// Stable listing for Settings: newest first, then by team so equal
    /// timestamps never reorder between launches.
    func listed() -> [TeamChannelEntry] {
        entries.compactMap { storageKey, preference -> TeamChannelEntry? in
            let parts = storageKey.components(separatedBy: "|")
            guard parts.count == 2 else { return nil }
            return TeamChannelEntry(key: TeamChannelKey(league: parts[0], abbreviation: parts[1], name: parts[1]),
                                    preference: preference)
        }
        .sorted {
            $0.preference.savedAt == $1.preference.savedAt
                ? $0.preference.teamName.localizedCaseInsensitiveCompare($1.preference.teamName) == .orderedAscending
                : $0.preference.savedAt > $1.preference.savedAt
        }
    }

    /// The whole decision, in one pure function.
    ///
    /// - Parameters:
    ///   - matchingReady: whether per-game matching has settled. Nothing below
    ///     can be answered without it, saved preference included.
    ///   - availableStreamIDs: channels the active provider currently carries.
    ///   - verifiedStreamIDs: channels that current guide evidence says are
    ///     carrying *this* game, tested with the same rules that authorize
    ///     normal playback. A channel can be available and not verified — the
    ///     regional network exists all season but only carries some of the
    ///     games — and that difference is the whole point of this type.
    ///   - verifiedStreamID: Lineup's own match for the game, if it has one.
    func resolve(_ game: TeamChannelGame,
                 matchingReady: Bool,
                 availableStreamIDs: Set<Int>,
                 verifiedStreamIDs: Set<Int>,
                 verifiedStreamID: Int?) -> PreferredChannel {
        // Every branch below rests on per-game evidence, and an incomplete index
        // has none: it makes every game look unmatched, so a preference, a
        // fallback, a picker or a "no channel" message built on it would be a
        // guess presented as an answer. A saved preference is not an exception —
        // it is a preference *among channels carrying this game*, never an
        // override of the evidence that decides which those are.
        guard matchingReady else { return .syncing }

        let home = usable(preference(for: game.homeKey), team: game.homeTeam,
                          available: availableStreamIDs, verified: verifiedStreamIDs)
        let away = usable(preference(for: game.awayKey), team: game.awayTeam,
                          available: availableStreamIDs, verified: verifiedStreamIDs)
        switch (home, away) {
        case let (home?, away?) where home.streamID != away.streamID:
            // Both saved channels are carrying this game and they disagree.
            return .chooseFeed(home: home, away: away)
        case let (home?, _?):
            // Both teams point at the same channel: nothing to ask about.
            return .play(streamID: home.streamID, source: .homePreference)
        case let (home?, nil):
            return .play(streamID: home.streamID, source: .homePreference)
        case let (nil, away?):
            // Only one side's preference is carrying the game, so there is no
            // conflict to raise even when the other team also has one saved.
            return .play(streamID: away.streamID, source: .awayPreference)
        case (nil, nil):
            break
        }

        // The saved channel is not carrying this game — the regional network on
        // a night the game is national, or a channel the provider has dropped.
        // Lineup's own verified feed takes it from here, and the preference is
        // kept either way: it decides the next game, not this one.
        if let verifiedStreamID, availableStreamIDs.contains(verifiedStreamID) {
            return .play(streamID: verifiedStreamID, source: .verified)
        }
        return .pick
    }

    /// A saved preference is usable only when the provider still carries the
    /// channel *and* evidence says it is carrying this game. Both conditions
    /// are required; neither one deletes the preference when it fails.
    private func usable(_ preference: TeamChannelPreference?, team: String,
                        available: Set<Int>, verified: Set<Int>) -> TeamFeedOption? {
        guard let preference,
              available.contains(preference.streamID),
              verified.contains(preference.streamID) else { return nil }
        return TeamFeedOption(team: team, streamID: preference.streamID,
                              channelName: preference.channelName)
    }
}
