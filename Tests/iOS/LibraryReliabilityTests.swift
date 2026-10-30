import XCTest
import Observation
#if os(iOS)
import SwiftUI
import UIKit
#endif
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

@MainActor
final class LibraryReliabilityTests: XCTestCase {
    private func cachedFixture(itemCount: Int) throws -> (MediaServerProfile, UserDefaults, URL) {
        let profile = MediaServerProfile(name: "Cached", serverURL: "https://cache.invalid", username: "viewer", userID: "viewer")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LibraryCacheResponsiveness.\(profile.id)"))
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        let root = MediaItem(id: "movies", name: "Cached Movies", type: "CollectionFolder", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        let items = (0..<itemCount).map { index in
            MediaItem(id: "film-\(index)", name: "Cached Film \(index)", type: "Movie", overview: "Cached metadata",
                productionYear: 2026, primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        }
        let snapshot = MediaLibrary.LibrarySnapshot(roots: [root], collections: [], importedCatalogs: [],
            catalogs: [MediaCatalog(root: root, items: items)], counts: nil, refreshedAt: Date(),
            siloPlayback: nil, siloFavorites: nil)
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lineup-media-library-\(profile.id.uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        return (profile, defaults, url)
    }

    func testLargeLaunchCacheYieldsTheUIActorAndSettingsTitleDoesNotObserveItemMetadata() async throws {
        let (profile, defaults, file) = try cachedFixture(itemCount: 30_000)
        defer {
            defaults.removePersistentDomain(forName: "LibraryCacheResponsiveness.\(profile.id)")
            try? FileManager.default.removeItem(at: file)
        }
        let state = LibraryCacheHeartbeat()
        let heartbeat = Task { @MainActor in
            while !state.finished { state.count += 1; await Task.yield() }
        }
        let library = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""), trackingKey: { nil })
        await library.restoreCachedLibrary()
        state.finished = true
        await heartbeat.value
        XCTAssertGreaterThan(state.count, 0, "Reading/decoding a large Library must not hold up the app's root")
        XCTAssertEqual(library.state(of: profile).catalogs.first?.items.count, 30_000)
        XCTAssertEqual(library.heroCatalogTitle, "Cached Movies")
        withObservationTracking {
            XCTAssertEqual(library.heroCatalogTitle, "Cached Movies")
        } onChange: {
            MainActor.assumeIsolated { state.invalidated = true }
        }
        library.setMetadataSource(.provider)
        library.setMetadataSource(.provider, episodes: true)
        XCTAssertFalse(state.invalidated, "Settings' shelf title must not depend on remapping item metadata")
        XCTAssertEqual(library.heroCatalog?.title, library.heroCatalogTitle)
    }

    func testRemovingAProfileDuringCacheRestoreCannotRestoreItsShelves() async throws {
        let (profile, defaults, file) = try cachedFixture(itemCount: 100)
        defer {
            defaults.removePersistentDomain(forName: "LibraryCacheResponsiveness.\(profile.id)")
            try? FileManager.default.removeItem(at: file)
        }
        let library = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""), trackingKey: { nil })
        library.remove(profile)
        await library.restoreCachedLibrary()
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertTrue(library.catalogs.isEmpty)
        XCTAssertNil(library.servers[profile.id])
    }

    #if os(iOS)
    func testRealSettingsRetainsItsScrollableListDuringPlaybackUpdatesWithALargeLibrary() async throws {
        let (profile, defaults, file) = try cachedFixture(itemCount: 30_000)
        defer {
            defaults.removePersistentDomain(forName: "LibraryCacheResponsiveness.\(profile.id)")
            try? FileManager.default.removeItem(at: file)
        }
        let media = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""), trackingKey: { nil },
            serverClientFactory: { _ in throw URLError(.notConnectedToInternet) })
        await media.restoreCachedLibrary()
        let library = SportsLibrary(profileDefaults: defaults, automaticRefreshes: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MainView(initialTab: .settings)
            .environment(library).environment(media).environmentObject(CloudSettingsSync.shared).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        func scroll(in view: UIView) -> UIScrollView? {
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        func navigationProbe(in view: UIView) -> MobileTabBarAppearance.Probe? {
            if let probe = view as? MobileTabBarAppearance.Probe { return probe }
            return view.subviews.lazy.compactMap { navigationProbe(in: $0) }.first
        }
        let deadline = Date().addingTimeInterval(5)
        while (scroll(in: window) == nil || navigationProbe(in: window)?.navigation?.tabs == nil), Date() < deadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let list = try XCTUnwrap(scroll(in: window))
        list.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        window.layoutIfNeeded()
        let offset = list.contentOffset.y
        let diagnostics = PlaybackDiagnostics.shared, wasEnabled = diagnostics.isEnabled
        diagnostics.isEnabled = true
        defer { diagnostics.isEnabled = wasEnabled }
        for index in 0..<20 {
            diagnostics.record("Settings responsiveness sample \(index)")
            await Task.yield()
            window.layoutIfNeeded()
            XCTAssertTrue(scroll(in: window) === list, "Playback updates must not replace the Settings list")
            XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1, "Settings must not jump while the player publishes diagnostics")
        }
        let navigation = try XCTUnwrap(navigationProbe(in: window)?.navigation)
        let tabs = try XCTUnwrap(navigation.tabs)
        XCTAssertEqual(tabs.selectedIndex, navigation.order.firstIndex(of: .settings))
        let previousGlass = UserDefaults.standard.object(forKey: MobileNavigationStyle.glassKey)
        defer {
            if let previousGlass { UserDefaults.standard.set(previousGlass, forKey: MobileNavigationStyle.glassKey) }
            else { UserDefaults.standard.removeObject(forKey: MobileNavigationStyle.glassKey) }
        }
        // Sample the transition itself in the production tab container. An
        // endpoint-only check misses a page that jumps and returns meanwhile.
        for glass in [false, true] {
            UserDefaults.standard.set(glass, forKey: MobileNavigationStyle.glassKey)
            navigation.expand()
            try await Task.sleep(for: .milliseconds(450))
            window.layoutIfNeeded()
            XCTAssertTrue(scroll(in: window) === list)
            list.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
            let before = list.contentOffset.y
            navigation.scrollObservation.discoverScrollViews(from: list)
            navigation.scrollObservation.receivePanInput(from: list, phase: .began, translation: .zero)
            navigation.scrollObservation.receivePanInput(from: list, phase: .changed, translation: CGPoint(x: 0, y: -65))
            var positions: [CGFloat] = []
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(16))
                window.layoutIfNeeded()
                positions.append(list.contentOffset.y)
                XCTAssertTrue(scroll(in: window) === list, "Compacting navigation must retain the real Settings list")
            }
            XCTAssertTrue(navigation.isCompact)
            XCTAssertLessThanOrEqual(positions.map { abs($0 - before) }.max() ?? 0, 1,
                "Settings must remain stable throughout the transition, not just after it settles")
            navigation.scrollObservation.receivePanInput(from: list, phase: .ended, translation: CGPoint(x: 0, y: -65))
            navigation.expand()
        }
        XCTAssertTrue(list.isScrollEnabled)
        XCTAssertEqual(media.heroCatalogTitle, "Cached Movies")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Settings-large-library"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    private func fixture() throws -> (MediaLibrary, MediaServerProfile, UserDefaults, URLSession) {
        let profile = MediaServerProfile(name: "Test", serverURL: "https://library-review.test/base", username: "viewer", userID: "viewer")
        let defaults = UserDefaults(suiteName: "LibraryReliability." + UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryReliabilityProtocol.self]
        let session = URLSession(configuration: configuration)
        let library = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""),
            trackingKey: { nil }, serverClientFactory: { profile in
                try JellyfinClient(serverURL: profile.serverURL, accessToken: "fixture", deviceID: "test", session: session)
            })
        return (library, profile, defaults, session)
    }

    func testConcurrentDetailsShareARequestAndReturnToEveryCaller() async throws {
        let (library, profile, _, session) = try fixture()
        defer { session.invalidateAndCancel(); LibraryReliabilityProtocol.reset() }
        let received = expectation(description: "detail request received")
        LibraryReliabilityProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/base/users/viewer/items/film")
            received.fulfill()
            return nil // Held until both callers have entered details.
        }
        let item = MediaItem(id: "film", name: "Film", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        let first = Task { try await library.details(of: item) }
        let second = Task { try await library.details(of: item) }
        await fulfillment(of: [received], timeout: 3)
        await Task.yield()
        LibraryReliabilityProtocol.release(#"{"Id":"film","Name":"Full record","Type":"Movie"}"#)
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.name, "Full record")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.serverID, profile.id)
        _ = try await library.details(of: item)
        XCTAssertEqual(LibraryReliabilityProtocol.requestCount, 1)
    }

    func testRemovingServerRejectsItsLateDetail() async throws {
        let (library, profile, _, session) = try fixture()
        defer { session.invalidateAndCancel(); LibraryReliabilityProtocol.reset() }
        let received = expectation(description: "old request received")
        LibraryReliabilityProtocol.install { _ in received.fulfill(); return nil }
        let item = MediaItem(id: "film", name: "Film", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        let load = Task { try await library.details(of: item) }
        await fulfillment(of: [received], timeout: 3)
        library.remove(profile)
        LibraryReliabilityProtocol.release(#"{"Id":"film","Name":"Stale","Type":"Movie"}"#)
        do { _ = try await load.value; XCTFail("Removed account must not return a late title") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertTrue(library.catalogs.isEmpty)
    }

    func testShelfFailureRetainsSnapshotButSuccessfulEmptyShelfClearsIt() async throws {
        let (library, profile, _, session) = try fixture()
        defer { library.remove(profile); session.invalidateAndCancel(); LibraryReliabilityProtocol.reset() }
        for phase in 0...2 {
            LibraryReliabilityProtocol.install { request in
                let path = request.url!.path
                if path.hasSuffix("/views") { return #"{"Items":[{"Id":"movies","Name":"Movies","Type":"CollectionFolder"}]}"# }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if query.first(where: { $0.name == "ParentId" })?.value == "movies" {
                    if phase == 1 { throw URLError(.timedOut) }
                    return phase == 0 ? #"{"Items":[{"Id":"film","Name":"Loaded film","Type":"Movie"}]}"# : #"{"Items":[]}"#
                }
                if path.hasSuffix("/addons") { return "[]" }
                return #"{"Items":[],"TotalRecordCount":0}"#
            }
            await library.reload()
            if phase == 0 {
                XCTAssertTrue(library.state(of: profile).catalogs.isEmpty, "Servers do not automatically add shelves")
                let root = try XCTUnwrap(library.state(of: profile).roots.first)
                await library.addShelf(root)
            }
            XCTAssertEqual(library.state(of: profile).loadFailed, phase == 1)
            XCTAssertFalse(library.state(of: profile).isLoading)
            XCTAssertEqual(library.state(of: profile).catalogs.first?.items.map(\.id), phase == 2 ? [] : ["film"])
        }
    }

    func testInventoryCoalescesAndDiscardsRemovedSource() async throws {
        let (library, profile, _, session) = try fixture()
        defer { session.invalidateAndCancel(); LibraryReliabilityProtocol.reset() }
        let received = expectation(description: "one full inventory request")
        LibraryReliabilityProtocol.install { _ in received.fulfill(); return nil }
        let a = Task { await library.combinedInventory() }
        let b = Task { await library.combinedInventory() }
        await fulfillment(of: [received], timeout: 3)
        await Task.yield()
        library.remove(profile)
        LibraryReliabilityProtocol.release(#"{"Items":[{"Id":"old","Name":"Old","Type":"Movie"}]}"#)
        let first = await a.value, second = await b.value
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertNotNil(first.failure)
        XCTAssertNotNil(second.failure)
        XCTAssertEqual(LibraryReliabilityProtocol.requestCount, 1)
    }
}

@MainActor
private final class LibraryCacheHeartbeat {
    var finished = false
    var count = 0
    var invalidated = false
}

private final class LibraryReliabilityProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> String?)?
    private static var held: [LibraryReliabilityProtocol] = []
    private static var count = 0
    private var stopped = false
    private var finished = false
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func install(_ value: @escaping (URLRequest) throws -> String?) {
        lock.lock(); defer { lock.unlock() }; handler = value
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; handler = nil; held = []; count = 0 }
    static func release(_ json: String) {
        lock.lock(); let waiting = held; held = []; lock.unlock()
        for entry in waiting { entry.finish(json) }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "library-review.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.held.append(self); let handler = Self.handler; Self.lock.unlock()
        do {
            if let json = try handler?(request) { finish(json) }
        } catch {
            Self.lock.lock(); Self.held.removeAll { $0 === self }; Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    private func finish(_ json: String) {
        Self.lock.lock(); let active = !stopped && !finished; finished = true
        Self.held.removeAll { $0 === self }; Self.lock.unlock()
        guard active else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
}
