import Foundation
import TVServices

/// What the Apple TV home screen shows above Lineup when it sits in the top
/// row: the followed teams' games, then whatever is part-watched.
///
/// Everything here comes from the shelf the app writes (`HomeShelfStore`).
/// The extension fetches nothing itself -- the system loads the images from
/// the addresses given -- so there is nothing to wait for, and the content is
/// handed back as soon as the file is read.
///
/// With nothing to show, the answer is nil rather than an empty section, which
/// leaves the app's own Top Shelf image in place instead of a blank row.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        completionHandler(Self.content(now: Date()))
    }

    private static func content(now: Date) -> TVTopShelfContent? {
        guard let shelf = HomeShelfStore.read() else { return nil }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        let games = HomeShelfGame.current(shelf.games, at: now).map { gameItem($0, now: now) }
        if !games.isEmpty {
            let section = TVTopShelfItemCollection<TVTopShelfSectionedItem>(items: games)
            section.title = "My Teams"
            sections.append(section)
        }

        let titles = shelf.continueWatching.map { mediaItem($0) }
        if !titles.isEmpty {
            let section = TVTopShelfItemCollection<TVTopShelfSectionedItem>(items: titles)
            section.title = "Continue Watching"
            sections.append(section)
        }

        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }

    // MARK: - Items

    /// A game as a square tile: the home side's badge, the away side's when
    /// the schedule has no home badge, and the matchup underneath.
    private static func gameItem(_ game: HomeShelfGame, now: Date) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: "game." + game.id)
        item.imageShape = .square
        item.title = title(for: game, now: now)
        if let address = game.homeLogo ?? game.awayLogo, let url = URL(string: address) {
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
        }
        let action = TVTopShelfAction(url: game.link.url)
        item.displayAction = action
        item.playAction = action
        return item
    }

    /// A part-watched title as a 16:9 tile with its progress under it.
    private static func mediaItem(_ media: HomeShelfMedia) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: "media." + media.id)
        item.imageShape = .hdtv
        item.title = media.title
        if let address = media.imageURL ?? media.posterURL, let url = URL(string: address) {
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
        }
        item.playbackProgress = media.progress
        let action = TVTopShelfAction(url: media.link.url)
        item.displayAction = action
        item.playAction = action
        return item
    }

    /// "BOS @ NYY · 7:05 PM" ahead of the game, "BOS 3 – NYY 5 · LIVE Q3"
    /// while it is on.
    private static func title(for game: HomeShelfGame, now: Date) -> String {
        let when: String
        if game.showsAsLive(at: now) {
            when = game.status.isEmpty ? "LIVE" : "LIVE " + game.status
        } else {
            when = game.startLabel(relativeTo: now)
        }
        return game.matchupLine(at: now) + " \u{00B7} " + when
    }
}
