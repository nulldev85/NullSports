import Foundation

/// The sports the viewer has turned off, kept on this device by league. A
/// hidden league leaves the list of games, the list of leagues and the live
/// scores; nothing else about it changes, and teams followed in it stay
/// followed. The iPhone and Apple TV keep it under the same key.
enum SportsVisibility {
    static let storageKey = "lineup.mobile.sports.hiddenLeagues.v1"

    static func hidden(_ raw: String) -> Set<SportsLeague> {
        Set(raw.split(separator: ",").compactMap { SportsLeague(rawValue: String($0)) })
    }

    /// The stored list with one league turned on or off. One league always
    /// stays on: a Sports screen with nothing in it is no use to anybody.
    static func setting(_ league: SportsLeague, hidden isHidden: Bool, in raw: String) -> String {
        var leagues = hidden(raw)
        if isHidden { leagues.insert(league) } else { leagues.remove(league) }
        guard leagues.count < SportsLeague.allCases.count else { return raw }
        return SportsLeague.allCases.filter(leagues.contains).map(\.rawValue).joined(separator: ",")
    }
}
