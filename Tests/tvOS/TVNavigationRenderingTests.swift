import XCTest
import SwiftUI
import UIKit
@testable import Lineup

@MainActor
final class TVNavigationRenderingTests: XCTestCase {
    func testTickerHasOneBoundedStripAndStopsOffScreenWhileRetainingFreshScores() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let ticker = TVScoreTickerController { entries in AnyView(Text(entries.first?.game.awayScore ?? "Empty")) }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ticker
        window.makeKeyAndVisible()
        defer { ticker.pause(); window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()
        var games = (0..<5_000).map { game("\($0)", score: "1") }
        ticker.update(events: games, active: true) { entries in AnyView(Text(entries.first?.game.awayScore ?? "Empty")) }
        let deadline = Date().addingTimeInterval(2)
        while !ticker.hasScheduledAdvance, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertLessThanOrEqual(ticker.renderedEntries.count, 6)
        XCTAssertEqual(ticker.renderedEntries.first?.game.id, "0")
        XCTAssertTrue(ticker.hasScheduledAdvance)
        XCTAssertEqual(ticker.animationCount, 1)
        games[0] = game("0", score: "3")
        ticker.update(events: games, active: true) { entries in AnyView(Text(entries.first?.game.awayScore ?? "Empty")) }
        XCTAssertEqual(ticker.renderedEntries.first?.game.awayScore, "3")
        XCTAssertEqual(ticker.animationCount, 1, "Updating a score must not accumulate animations")
        ticker.beginAppearanceTransition(false, animated: false)
        ticker.endAppearanceTransition()
        ticker.update(events: games, active: true) { _ in AnyView(EmptyView()) }
        XCTAssertFalse(ticker.hasScheduledAdvance, "A retained offscreen tab must stay idle even before its input updates")
        XCTAssertEqual(ticker.animationCount, 0)
        ticker.update(events: games, active: false) { _ in AnyView(EmptyView()) }
        await Task.yield()
        XCTAssertFalse(ticker.hasScheduledAdvance)
        XCTAssertEqual(ticker.animationCount, 0, "Leaving Sports must stop the crawl")
        ticker.beginAppearanceTransition(true, animated: false)
        ticker.endAppearanceTransition()
        ticker.update(events: games, active: true) { _ in AnyView(EmptyView()) }
        XCTAssertTrue(ticker.hasScheduledAdvance, "Returning to Sports must resume its bounded crawl")
        ticker.update(events: [], active: true) { _ in AnyView(EmptyView()) }
        XCTAssertTrue(ticker.renderedEntries.isEmpty)
        XCTAssertFalse(ticker.hasScheduledAdvance, "An empty ticker must be idle")
        XCTAssertEqual(ticker.animationCount, 0)
    }

    func testLibraryFocusDoesNotRebuildHistoryAndInactiveSourcesRefreshOnReturn() async throws {
        let suite = "TVLibraryBrowseRows.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = MediaServerProfile(name: "Server", serverURL: "http://server.invalid", username: "viewer", userID: "viewer")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        defaults.set(profile.id.uuidString, forKey: "NullSports.activeMediaServer")
        let media = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""), trackingKey: { nil })
        let rows = TVLibraryBrowseRows()
        let movie = item("movie", name: "Movie", profile: profile.id)
        _ = rows.snapshot(in: media, active: true)
        for _ in 0..<200 { _ = rows.snapshot(in: media, active: true) }
        XCTAssertEqual(rows.preparationCount, 1, "Moving remote focus must reuse the history join")
        media.trackPlayback(of: movie, position: 300, duration: 3_600)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(rows.snapshot(in: media, active: true).continuing.first?.item.id, "movie")
        let count = rows.preparationCount
        _ = rows.snapshot(in: media, active: false)
        media.setLocalFavorite(true, for: movie)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(rows.snapshot(in: media, active: false).titles.isEmpty)
        XCTAssertEqual(rows.preparationCount, count, "An inactive Library must not rebuild its browse rows")
        XCTAssertEqual(rows.snapshot(in: media, active: true).titles.first?.id, "movie")
        XCTAssertEqual(rows.preparationCount, count + 1)
    }

    func testLargeShelfContentKeyChecksOnlyTheFocusedItemAndSmallContinueWatchingRow() {
        let profile = UUID()
        var items = (0..<30_000).map { item("\($0)", name: "Movie \($0)", profile: profile) }
        func key(_ id: String) -> TVLibraryContentsKey {
            TVLibraryContentsKey(shelf: TVLibraryShelf(id: id, title: "Shelf", label: nil,
                items: items, opensPages: false, catalog: nil), focus: .card(10))
        }
        let original = key("large")
        items[20_000] = item("20000", name: "Updated", profile: profile)
        XCTAssertEqual(key("large"), original, "Unfocused metadata must not invalidate the row's content observer")
        items[10] = item("10", name: "Focused Update", profile: profile)
        XCTAssertNotEqual(key("large"), original)
        XCTAssertTrue(key("large").continueIDs.isEmpty)
        XCTAssertEqual(key(LibraryShelfOrder.continueWatching).continueIDs.count, 20)
    }

    func testSuspendedFocusedPreviewCanFinishItsDetailsAfterReturning() async throws {
        let preview = TVMediaPreviewState(), profile = UUID()
        let plain = item("movie", name: "Plain", profile: profile)
        let rich = item("movie", name: "Rich", profile: profile)
        let entered = expectation(description: "First details request started")
        var release: CheckedContinuation<Void, Never>?
        defer { preview.suspend(); release?.resume() }
        var loads = 0
        func load(_ item: MediaItem) async -> MediaItem? {
            loads += 1
            if loads == 1 {
                await withCheckedContinuation { release = $0; entered.fulfill() }
            }
            return rich
        }
        preview.focus(plain, focused: true, load: load)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(preview.item?.name, "Plain")
        preview.suspend()
        release?.resume(); release = nil
        await Task.yield()
        XCTAssertEqual(preview.item?.name, "Plain", "An old response must not publish after suspension")
        preview.focus(plain, focused: true, load: load)
        let deadline = Date().addingTimeInterval(2)
        while preview.item?.name != "Rich", Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(preview.item?.name, "Rich")
        XCTAssertEqual(loads, 2)
        preview.focus(plain, focused: true, load: load)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(loads, 2, "Completed details must stay cached on return")
        preview.suspend()
    }

    private func item(_ id: String, name: String, profile: UUID) -> MediaItem {
        MediaItem(id: id, name: name, type: "Movie", overview: nil, productionYear: nil,
            primaryImageAspectRatio: nil, childCount: nil, serverID: profile)
    }

    private func game(_ id: String, score: String) -> SportsGame {
        SportsGame(id: id, league: .nhl, start: Date(), awayTeam: "New Jersey", homeTeam: "Colorado",
            awayAbbreviation: "NJ", homeAbbreviation: "COL", awayLogo: "", homeLogo: "", awayScore: score,
            homeScore: "2", awayColor: "FF0000", homeColor: "0000FF", awayRecord: nil, homeRecord: nil,
            venue: nil, location: nil, status: "Live", state: "in", broadcast: "ESPN", eventName: nil)
    }
}
