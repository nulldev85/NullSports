import Foundation
import TVServices

/// The Home Screen's banner for Lineup: this week's trending films and shows,
/// each on its own backdrop, turning over on their own while Lineup sits in
/// the top row.
///
/// The extension asks TMDB itself, with the app's own read-only key. It runs
/// apart from the app and before it has opened, so nothing it shows can wait
/// on the app's own lists or servers; with no key, or no answer, it gives
/// nothing and the Home Screen keeps Lineup's still Top Shelf image.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task {
            let items = await TopShelfTrending.load()
            guard !items.isEmpty else { completionHandler(nil); return }
            completionHandler(TVTopShelfCarouselContent(style: .details, items: items.map(Self.item)))
        }
    }

    private static func item(_ title: TopShelfTrending.Title) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: title.id)
        item.title = title.name
        item.contextTitle = title.isShow ? "Trending Show" : "Trending Movie"
        item.summary = title.overview
        if let year = title.year { item.creationDate = year }
        item.setImageURL(title.backdrop, for: .screenScale1x)
        item.setImageURL(title.backdropLarge, for: .screenScale2x)
        // Choosing one opens Lineup.
        if let open = URL(string: "lineup://trending") {
            item.displayAction = TVTopShelfAction(url: open)
            item.playAction = TVTopShelfAction(url: open)
        }
        return item
    }
}

/// TMDB's trending lists, films and shows taken in turn.
enum TopShelfTrending {
    struct Title {
        let id: String
        let name: String
        let overview: String?
        let year: Date?
        let isShow: Bool
        let backdrop: URL
        let backdropLarge: URL
    }

    private struct Page: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let overview: String?
        let backdrop_path: String?
        let release_date: String?
        let first_air_date: String?
        let adult: Bool?
    }

    /// The most the banner carries: enough to keep turning over without the
    /// system having to fetch a wall of pictures.
    static let limit = 12

    static func load() async -> [Title] {
        guard let token = token() else { return [] }
        async let films = fetch("movie", token: token)
        async let shows = fetch("tv", token: token)
        let (movies, series) = await (films, shows)
        // One film, one show, and so on.
        var mixed: [Title] = []
        for index in 0..<max(movies.count, series.count) {
            if index < movies.count { mixed.append(movies[index]) }
            if index < series.count { mixed.append(series[index]) }
        }
        return Array(mixed.prefix(limit))
    }

    private static func fetch(_ kind: String, token: String) async -> [Title] {
        guard let url = URL(string: "https://api.themoviedb.org/3/trending/\(kind)/week?language=en-US") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        let isShow = kind == "tv"
        let dates = DateFormatter()
        dates.dateFormat = "yyyy-MM-dd"
        dates.locale = Locale(identifier: "en_US_POSIX")
        return page.results.compactMap { result in
            // A banner is a backdrop: a title without one is passed over.
            guard result.adult != true, let path = result.backdrop_path, !path.isEmpty,
                  let name = result.title ?? result.name, !name.isEmpty,
                  let small = URL(string: "https://image.tmdb.org/t/p/w1280" + path),
                  let large = URL(string: "https://image.tmdb.org/t/p/original" + path) else { return nil }
            let date = (result.release_date ?? result.first_air_date).flatMap { dates.date(from: $0) }
            let overview = result.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Title(id: (isShow ? "tv-" : "movie-") + String(result.id), name: name,
                         overview: overview?.isEmpty == false ? overview : nil,
                         year: date, isShow: isShow, backdrop: small, backdropLarge: large)
        }
    }

    /// The app's TMDB key, bundled with this extension as it is with the app.
    private static func token() -> String? {
        guard let url = Bundle.main.url(forResource: "LineupMetadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = values["tmdb"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }
}
