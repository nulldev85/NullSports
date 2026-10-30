import XCTest
import SwiftUI
import UIKit
@testable import Lineup

@MainActor
final class TVSettingsTests: XCTestCase {
    func testColumnsAndAllCategoriesFitSupportedTVViewports() {
        XCTAssertEqual(TVSettingsCategory.allCases.count, 8)
        XCTAssertEqual(Set(TVSettingsCategory.allCases.map(\.id)).count, 8)
        for size in [CGSize(width: 1280, height: 600), CGSize(width: 1280, height: 720),
                     CGSize(width: 1920, height: 960), CGSize(width: 1920, height: 1080),
                     CGSize(width: 3840, height: 2160)] {
            let layout = TVSettingsLayout(size: size)
            XCTAssertEqual(layout.sidebarWidth + layout.contentWidth + layout.descriptionWidth + layout.inset * 2,
                           layout.panelWidth, accuracy: 0.1)
            XCTAssertGreaterThan(layout.contentWidth - 48, 380, "The settings list must retain readable width")
            XCTAssertGreaterThan(layout.descriptionWidth - 32, 180)
            let sidebarHeight = layout.sidebarRowHeight * 8 + layout.sidebarSpacing * 7
                + (layout.compactHeight ? 64 : 80)
            XCTAssertLessThanOrEqual(sidebarHeight, size.height - 56 - 46 - layout.verticalInset * 2 + 1,
                                     "Every category must remain reachable without a second scrolling sidebar")
        }
    }

    func testEveryCategoryRendersWithOnlyTheSettingsColumnScrollingAndKeepsSavedEngines() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let suite = "TVSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let providers = [XtreamProfile(name: "Main TV", serverURL: "https://main.invalid", username: "viewer"),
                         XtreamProfile(name: "Sports TV", serverURL: "https://sports.invalid", username: "viewer")]
        let servers = [MediaServerProfile(name: "Movies", serverURL: "https://movies.invalid", username: "viewer", userID: "movies"),
                       MediaServerProfile(name: "Shows", serverURL: "https://shows.invalid", username: "viewer", userID: "shows")]
        defaults.set(try JSONEncoder().encode(providers), forKey: "NullSports.profiles")
        defaults.set(providers[0].id.uuidString, forKey: "NullSports.activeProfile")
        defaults.set(try JSONEncoder().encode(servers), forKey: "NullSports.mediaServers")
        let library = SportsLibrary(profileDefaults: defaults,
            credentials: .init(password: { _ in nil }, save: { _, _ in }, delete: { _ in }), automaticRefreshes: false)
        let media = MediaLibrary(defaults: defaults, trackingKey: { nil },
                                serverClientFactory: { _ in throw URLError(.notConnectedToInternet) })
        let standard = UserDefaults.standard
        let keys = [TVPlaybackEngine.storageKey] + TVPlaybackPlace.allCases.map(\.storageKey)
        let old = Dictionary(keys.map { ($0, standard.object(forKey: $0)) }, uniquingKeysWith: { first, _ in first })
        let engines: [TVPlaybackEngine] = [.vlc, .aether, .mpv, .vlc]
        for (place, engine) in zip(TVPlaybackPlace.allCases, engines) { standard.set(engine.rawValue, forKey: place.storageKey) }
        defer {
            for key in keys {
                if let value = old[key] ?? nil { standard.set(value, forKey: key) }
                else { standard.removeObject(forKey: key) }
            }
        }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        for category in TVSettingsCategory.allCases {
            let host = UIHostingController(rootView: AccountView(selectedTab: .constant(3), initialCategory: category)
                .environment(library).environment(media)
                .environmentObject(CloudSettingsSync.shared).preferredColorScheme(.dark))
            window.rootViewController = host
            window.makeKeyAndVisible()
            let ready = expectation(description: "\(category.title) layout attached")
            var attached = false
            let timeout = Date().addingTimeInterval(5)
            while Date() < timeout {
                window.layoutIfNeeded()
                if let scroll = mainScroll(in: host.view), scroll.window === window,
                   scroll.bounds.height > 200, scroll.contentSize.height > 0 {
                    attached = true
                    ready.fulfill()
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            await fulfillment(of: [ready], timeout: 0.1)
            guard attached else { continue }
            let scroll = try XCTUnwrap(mainScroll(in: host.view))
            let frame = scroll.convert(scroll.bounds, to: window)
            XCTAssertGreaterThan(frame.minX, window.bounds.width * 0.22, "The sidebar must sit outside the scrolling list")
            XCTAssertLessThan(frame.maxX, window.bounds.width * 0.88, "The description rail must sit outside the scrolling list")
            XCTAssertGreaterThan(frame.width, 380)
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "TV-Settings-\(category.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for (place, expected) in zip(TVPlaybackPlace.allCases, engines) {
            XCTAssertEqual(TVPlaybackEngine.selected(for: place), expected,
                           "Restyling and visiting settings must not rewrite a tab’s saved playback engine")
        }
        XCTAssertEqual(library.profiles.map(\.id), providers.map(\.id))
        XCTAssertEqual(media.profiles.map(\.id), servers.map(\.id))
    }

    private func mainScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 200,
           scroll.bounds.width > 380, scroll.bounds.width < (view.window?.bounds.width ?? 1920) * 0.75 { return scroll }
        for child in view.subviews { if let scroll = mainScroll(in: child) { return scroll } }
        return nil
    }
}
