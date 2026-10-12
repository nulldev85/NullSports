import Foundation
import ImageIO
import SwiftUI
import UIKit
import WidgetKit

@main
struct LineupWidgets: WidgetBundle {
    var body: some Widget {
        MyTeamsWidget()
    }
}

/// The followed teams' next games on the Home Screen and the Lock Screen.
///
/// Everything it draws comes from the shelf the app writes into the App Group
/// (`HomeShelfStore`). The widget has no provider, no schedule and no scores of
/// its own; what it adds is time. A game the app wrote down as "7:05 PM" reads
/// as live once it is past five past seven, and drops off once it must be
/// over, without the app being opened in between.
struct MyTeamsWidget: Widget {
    let kind = "MyTeams"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MyTeamsProvider()) { entry in
            MyTeamsView(entry: entry)
        }
        .configurationDisplayName("My Teams")
        .description("When your teams play next, and the score while they do.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct MyTeamsEntry: TimelineEntry {
    let date: Date
    /// The games to draw at `date`, live first.
    let games: [HomeShelfGame]
    /// What to say when there are no games to draw.
    let empty: MyTeamsEmpty
    /// Each badge the entry draws, already shrunk, keyed by its address. A
    /// widget's views cannot load anything themselves, so whatever is not in
    /// here is drawn as the team's abbreviation instead.
    let logos: [String: Data]

    func logo(_ address: String?) -> UIImage? {
        guard let address, let data = logos[address] else { return nil }
        return UIImage(data: data)
    }

    /// For the placeholder and for the widget gallery before any team is
    /// followed: something shaped like a real game.
    static func sample(at date: Date) -> MyTeamsEntry {
        let game = HomeShelfGame(
            id: "sample", league: "MLB", awayName: "Boston", homeName: "New York",
            awayAbbreviation: "BOS", homeAbbreviation: "NYY", awayLogo: nil, homeLogo: nil,
            awayScore: nil, homeScore: nil, awayRank: nil, homeRank: nil,
            start: date.addingTimeInterval(2 * 60 * 60), isLive: false, status: "",
            channelName: nil, isEvent: false, eventName: nil)
        return MyTeamsEntry(date: date, games: [game], empty: .noGames, logos: [:])
    }
}

/// Why the widget has no games to show, which decides what it says instead.
enum MyTeamsEmpty {
    case noGames
    case noTeams
    /// The app has not written a shelf yet: installed, never opened since.
    case notOpened
    /// This install cannot open the App Group, so nothing the app writes
    /// can reach the widget.
    case unreachable

    init(_ reading: HomeShelfStore.Reading) {
        switch reading {
        case .unreachable: self = .unreachable
        case .nothingYet: self = .notOpened
        // A shelf from before it said whether teams were followed: any
        // games on it mean they were.
        case .shelf(let shelf): self = (shelf.followsTeams ?? !shelf.games.isEmpty) ? .noGames : .noTeams
        }
    }

    var message: String {
        switch self {
        case .noGames: return "No games for your teams in the next two days."
        case .noTeams: return "Follow teams in Lineup to see their games here."
        case .notOpened: return "Open Lineup to bring your teams here."
        case .unreachable: return "This install of Lineup can't share its games with widgets."
        }
    }

    var shortMessage: String {
        switch self {
        case .noGames: return "No games in the next two days"
        case .noTeams: return "Follow teams in Lineup"
        case .notOpened: return "Open Lineup to load your teams"
        case .unreachable: return "Can't reach Lineup's games"
        }
    }
}

struct MyTeamsProvider: TimelineProvider {
    /// Entries in one timeline. Each is a moment the picture changes by
    /// itself, so ten covers more than the half hour before the next reload.
    private static let maxEntries = 10

    func placeholder(in context: Context) -> MyTeamsEntry {
        .sample(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (MyTeamsEntry) -> Void) {
        let now = Date()
        let reading = HomeShelfStore.reading()
        let games = HomeShelfGame.current(reading.shelf?.games ?? [], at: now)
        if context.isPreview && games.isEmpty {
            completion(.sample(at: now))
            return
        }
        let family = context.family
        let empty = MyTeamsEmpty(reading)
        Task {
            let logos = await LogoLoader.load(Self.logoAddresses(for: [games], family: family))
            completion(MyTeamsEntry(date: now, games: games, empty: empty, logos: logos))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MyTeamsEntry>) -> Void) {
        let family = context.family
        Task {
            let timeline = await Self.timeline(now: Date(), family: family)
            completion(timeline)
        }
    }

    private static func timeline(now: Date, family: WidgetFamily) async -> Timeline<MyTeamsEntry> {
        let reading = HomeShelfStore.reading()
        let games = reading.shelf?.games ?? []
        let empty = MyTeamsEmpty(reading)

        // An entry for now, and one for each moment the picture changes on its
        // own: a game starting, which turns it live, and a game reaching its
        // assumed end, which takes it off.
        let changes = Set(games.flatMap { [$0.start, $0.assumedEnd] }).filter { $0 > now }
        var dates = [now]
        dates.append(contentsOf: changes.sorted().prefix(maxEntries - 1))
        let slates = dates.map { HomeShelfGame.current(games, at: $0) }

        let logos = await LogoLoader.load(logoAddresses(for: slates, family: family))
        let entries = dates.indices.map { index in
            MyTeamsEntry(date: dates[index], games: slates[index], empty: empty, logos: logos)
        }

        // Ask again within half an hour, or as a game starts if that is
        // sooner, in case the app has written something newer since.
        let soon = now.addingTimeInterval(30 * 60)
        let nextStart = games.map(\.start).filter { $0 > now }.min()
        let refresh = nextStart.map { min($0, soon) } ?? soon
        return Timeline(entries: entries, policy: .after(refresh))
    }

    /// The badges this family will actually draw: one game's on a small
    /// widget, three on a medium, none on the Lock Screen, which draws in one
    /// colour and has no room for them. Capped, because every one is held in
    /// memory for as long as the timeline is.
    private static func logoAddresses(for slates: [[HomeShelfGame]], family: WidgetFamily) -> [String] {
        let gamesDrawn: Int
        switch family {
        case .systemSmall: gamesDrawn = 1
        case .systemMedium: gamesDrawn = 3
        default: gamesDrawn = 0
        }
        var seen = Set<String>()
        var addresses: [String] = []
        for slate in slates {
            for game in slate.prefix(gamesDrawn) {
                for address in [game.awayLogo, game.homeLogo].compactMap({ $0 }) {
                    if seen.insert(address).inserted { addresses.append(address) }
                }
            }
        }
        return Array(addresses.prefix(LogoLoader.maxLogos))
    }
}

/// Team badges, fetched and shrunk while the timeline is built.
///
/// A badge from the schedule is a 500-pixel PNG, and a widget extension has a
/// few tens of megabytes in all. Each is decoded straight to a thumbnail no
/// larger than it is drawn, never at full size, and one that is slow or
/// missing is simply left out.
enum LogoLoader {
    static let maxLogos = 8
    /// Pixels on the longest side: a badge is drawn at 24 points at most, and
    /// three times that is enough for any iPhone screen.
    private static let pixels = 96

    static func load(_ addresses: [String]) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self, returning: [String: Data].self) { group in
            for address in addresses {
                group.addTask {
                    let data = await LogoLoader.logo(at: address)
                    return (address, data)
                }
            }
            var logos: [String: Data] = [:]
            for await (address, data) in group {
                if let data { logos[address] = data }
            }
            return logos
        }
    }

    private static func logo(at address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 5)
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = result.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return thumbnail(of: result.0)
    }

    private static func thumbnail(of data: Data) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image).pngData()
    }
}
