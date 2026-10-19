import Foundation

/// When a show's next episode airs, from TVmaze's public schedule.
///
/// A server lists only the episodes it has. Once a viewer had watched them
/// all, Continue Watching had nothing to hold the show by, and the show left
/// the row until the next episode arrived. TVmaze knows the episodes still to
/// come -- their number, name, air time and often a still -- without a key,
/// from the ids the server already keeps for the show.
enum TVMazeSchedule {
    struct Episode: Decodable, Equatable {
        let id: Int
        let name: String?
        let season: Int
        let number: Int?
        let airstamp: String?
        let image: Images?
        let summary: String?

        struct Images: Decodable, Equatable {
            let medium: String?
            let original: String?
        }
    }

    private struct Show: Decodable {
        let id: Int
    }

    /// The episode after season `season`, episode `number`, or nil when the
    /// show is not known or has nothing after it.
    static func nextEpisode(afterSeason season: Int, number: Int,
                            providerIDs: [String: String]) async -> Episode? {
        guard let showID = await showID(for: providerIDs),
              let url = URL(string: "https://api.tvmaze.com/shows/\(showID)/episodes"),
              let episodes: [Episode] = await fetch(url) else { return nil }
        return following(season: season, number: number, in: episodes)
    }

    /// The first numbered episode after this one, in airing order. Specials
    /// have no number and are passed over, as they are when watching.
    static func following(season: Int, number: Int, in episodes: [Episode]) -> Episode? {
        episodes
            .compactMap { episode in episode.number.map { (episode, $0) } }
            .filter { $0.0.season > 0 }
            .sorted { ($0.0.season, $0.1) < ($1.0.season, $1.1) }
            .first { ($0.0.season, $0.1) > (season, number) }?
            .0
    }

    /// TVmaze's own number for the show, looked up by the ids a server keeps.
    private static func showID(for ids: [String: String]) async -> Int? {
        let lookups = [("thetvdb", "Tvdb"), ("imdb", "Imdb")]
        for (parameter, key) in lookups {
            guard let value = ids.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
                  !value.isEmpty,
                  var components = URLComponents(string: "https://api.tvmaze.com/lookup/shows") else { continue }
            components.queryItems = [URLQueryItem(name: parameter, value: value)]
            if let url = components.url, let show: Show = await fetch(url) { return show.id }
        }
        return nil
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        let request = URLRequest(url: url, timeoutInterval: 12)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// A summary arrives as HTML; a card and a page want its words.
    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
