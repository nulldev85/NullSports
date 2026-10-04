import Foundation

/// The teams a viewer follows.
///
/// Keyed the same way a saved channel is -- league plus abbreviation, with the
/// normalised name as the fallback -- because it is the same question asked
/// twice and a second notion of team identity would drift from the first the
/// first time a feed changed how it spells a city.
///
/// What a follow is *for* is ordering. The app already knows every game today;
/// following says which of them a viewer came for, and everything downstream
/// reads from that: what sits at the top of the Live tab, what is worth a
/// notification, what the television offers before anything else.
struct FollowedTeam: Codable, Equatable, Sendable, Identifiable {
    /// The halves of `TeamChannelKey`, stored flat so the file survives a
    /// change to that type's internals.
    let league: String
    let team: String
    /// Carried along so a followed team can still be named and drawn when
    /// today's schedule happens not to include it.
    let name: String
    let abbreviation: String
    let logo: String
    let followedAt: Date

    var id: String { league + "|" + team }
    var key: TeamChannelKey {
        TeamChannelKey(league: league, abbreviation: abbreviation, name: name)
    }

    init(key: TeamChannelKey, name: String, abbreviation: String, logo: String,
         followedAt: Date = Date()) {
        self.league = key.league
        self.team = key.team
        self.name = name
        self.abbreviation = abbreviation
        self.logo = logo
        self.followedAt = followedAt
    }
}

/// Everyone a viewer follows, oldest first.
///
/// Order is the order they were followed rather than anything clever. A list
/// that rearranges itself on form or standing is a list nobody can find
/// anything in twice.
struct FollowedTeams: Codable, Equatable, Sendable {
    private(set) var teams: [FollowedTeam]

    init(_ teams: [FollowedTeam] = []) {
        self.teams = teams.sorted { $0.followedAt < $1.followedAt }
    }

    var isEmpty: Bool { teams.isEmpty }
    var count: Int { teams.count }

    func contains(_ key: TeamChannelKey) -> Bool {
        guard key.isUsable else { return false }
        return teams.contains { $0.id == key.storageKey }
    }

    mutating func follow(_ team: FollowedTeam) {
        guard team.key.isUsable, !contains(team.key) else { return }
        teams.append(team)
    }

    mutating func unfollow(_ key: TeamChannelKey) {
        teams.removeAll { $0.id == key.storageKey }
    }

    mutating func toggle(_ team: FollowedTeam) {
        if contains(team.key) { unfollow(team.key) } else { follow(team) }
    }
}

/// Whether a game is one of the viewer's.
///
/// Free of `SportsGame` on purpose, like the preference model it borrows its
/// key from: the whole rule can then be tested without the app's models or a
/// provider behind them.
enum FollowedSlate {
    static func follows(_ game: TeamChannelGame, in teams: FollowedTeams) -> Bool {
        guard !teams.isEmpty else { return false }
        return teams.contains(game.homeKey) || teams.contains(game.awayKey)
    }

    /// The sides of this game a viewer could follow or unfollow.
    ///
    /// An event with no two sides -- a fight card -- has nothing to follow, so
    /// it answers with nothing rather than with a team named after the event.
    static func sides(of game: TeamChannelGame) -> [TeamChannelKey] {
        [game.awayKey, game.homeKey].filter(\.isUsable)
    }
}
