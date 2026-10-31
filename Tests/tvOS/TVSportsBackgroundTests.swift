import XCTest
import SwiftUI
import UIKit
@testable import Lineup

@MainActor
final class TVSportsBackgroundTests: XCTestCase {
    private func game(_ id: String, away: String?, home: String?, score: String = "0") -> SportsGame {
        SportsGame(id: id, league: .nba, start: Date(timeIntervalSince1970: 1_800_000_000),
            awayTeam: "Orlando Magic", homeTeam: "Miami Heat", awayAbbreviation: "ORL", homeAbbreviation: "MIA",
            awayLogo: "", homeLogo: "", awayScore: score, homeScore: "12", awayColor: away, homeColor: home,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Live", state: "in",
            broadcast: "ABC", eventName: nil)
    }

    func testScoreRefreshKeepsTheSameColorIdentityAndMissingColorsUseTheRowFallback() {
        let original = game("one", away: "#FF0000", home: "#0000FF")
        let refreshed = game("one", away: "FF0000", home: "0000FF", score: "24")
        XCTAssertEqual(LiveEventColors(game: original), LiveEventColors(game: refreshed),
                       "A score update must not restart a background transition")
        let missingHome = LiveEventColors(game: game("two", away: "FF0000", home: nil))
        XCTAssertEqual(missingHome.home, missingHome.away)
        let invalid = LiveEventColors(game: game("three", away: "invalid", home: ""))
        XCTAssertEqual(invalid.away, LineupStyle.leagueColor(.nba))
        XCTAssertEqual(invalid.home, invalid.away)
    }

    func testRapidFocusChangesRetargetOneGradientWithoutAccumulatingLayers() {
        let view = LiveCanvasTintView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let layer = view.layer
        let red = LiveEventColors(game: game("red", away: "FF0000", home: "FF8800"))
        let blue = LiveEventColors(game: game("blue", away: "0000FF", home: "00AACC"))
        for index in 0..<200 {
            view.setColors(index.isMultiple(of: 2) ? red : blue, animated: true)
            XCTAssertTrue(view.layer === layer)
            XCTAssertTrue(layer.sublayers?.isEmpty ?? true)
            XCTAssertLessThanOrEqual(layer.animationKeys()?.count ?? 0, 1)
        }
        view.setColors(blue, animated: false)
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true,
                      "Enabling Reduce Motion must stop an in-flight transition even if focus stays put")
        view.setColors(nil, animated: false)
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true, "Reduce Motion must not retain a color animation")
    }

    func testRenderedCanvasChangesWithHighlightedGameAndReturnsToNeutralWithoutEvents() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let spotlight = LiveSpotlight()
        let red = game("red", away: "FF0000", home: "FF8800")
        let blue = game("blue", away: "0000FF", home: "00AACC")
        let host = UIHostingController(rootView: LiveCanvas(spotlight: spotlight, events: [red, blue])
            .transaction { transaction in
                // System accessibility values are read-only. Disable only this
                // rendering test's animations while observing the real view.
                transaction.disablesAnimations = true
                transaction.animation = nil
            })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }

        let redImage = try await rendered(window) { pixel in pixel.x > pixel.z + 0.015 }
        attach(redImage, name: "TV-Sports-background-red")
        spotlight.rest(on: blue, row: 1)
        let blueImage = try await rendered(window) { pixel in pixel.z > pixel.x + 0.015 }
        attach(blueImage, name: "TV-Sports-background-blue")
        for image in [redImage, blueImage] {
            let pixel = try sample(image)
            XCTAssertLessThan(max(pixel.x, pixel.y, pixel.z), 0.32,
                              "Team colors must remain a dark wash behind the interface")
        }
        host.rootView = LiveCanvas(spotlight: spotlight, events: [])
            .transaction { transaction in
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        let neutral = try await rendered(window) { pixel in
            max(pixel.x, pixel.y, pixel.z) - min(pixel.x, pixel.y, pixel.z) < 0.02
        }
        attach(neutral, name: "TV-Sports-background-empty")
    }

    func testActualSportsTabColorsReachTheTopAndBottomOfTheWindow() async throws {
        let suite = "TVFullScreenSportsCanvas.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let red = game("red", away: "FF0000", home: "FF8800")
        let blue = game("blue", away: "0000FF", home: "00AACC")
        let library = SportsLibrary(profileDefaults: defaults, automaticRefreshes: false,
            scheduleCacheLocation: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
            scheduleFetcher: { _ in .init(games: [.nba: [red, blue]], loadedLeagues: [.nba], errorMessage: nil) })
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        }
        library.refreshSchedule()
        let deadline = Date().addingTimeInterval(5)
        while library.gamesByLeague[.nba]?.count != 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.gamesByLeague[.nba]?.count, 2)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let spotlight = LiveSpotlight()
        let host = UIHostingController(rootView: TabView {
            LiveView(isActive: false, spotlight: spotlight)
                .tabItem { Label("Sports", systemImage: "play.rectangle") }
            Color.black.tabItem { Label("Other", systemImage: "gear") }
        }.environment(library).transaction {
            $0.disablesAnimations = true
            $0.animation = nil
        })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        // Check the real Sports/NavigationStack/ticker inside a native tab
        // container. A standalone canvas screenshot misses the clipping bug.
        for (event, redDominates) in [(red, true), (blue, false)] {
            spotlight.rest(on: event)
            let until = Date().addingTimeInterval(5)
            var image: UIImage?
            var matches = false
            var sampledPixels: [SIMD3<Double>] = []
            while !matches, Date() < until {
                window.layoutIfNeeded()
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let pixels = try [0.015, 0.5, 0.985].map {
                    try sample(rendered, x: 0.008, y: $0)
                }
                sampledPixels = pixels
                matches = pixels.allSatisfy { redDominates ? $0.x > $0.z + 0.015 : $0.z > $0.x + 0.015 }
                image = rendered
                if !matches { try await Task.sleep(for: .milliseconds(20)) }
            }
            XCTAssertTrue(matches, "Team wash must cover tab-bar, content and bottom screen edges: \(event.id), \(sampledPixels)")
            if let image { attach(image, name: "TV-Sports-full-screen-\(event.id)") }
        }
    }

    private func rendered(_ window: UIWindow, matching condition: (SIMD3<Double>) -> Bool) async throws -> UIImage {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if condition(try sample(image)) { return image }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "TVSportsBackgroundTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The rendered background did not follow the highlighted event"])
    }

    private func sample(_ image: UIImage, x: Double = 0.2, y: Double = 0.5) throws -> SIMD3<Double> {
        let cg = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: CGFloat(Double(cg.width) * x), y: CGFloat(Double(cg.height) * y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return SIMD3(Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
