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

    func testRenderedCanvasChangesWithHighlightedGameAndReturnsToNeutralWithoutEvents() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let spotlight = LiveSpotlight()
        let red = game("red", away: "FF0000", home: "FF8800")
        let blue = game("blue", away: "0000FF", home: "00AACC")
        let host = UIHostingController(rootView: LiveCanvas(spotlight: spotlight, events: [red, blue])
            .environment(\.accessibilityReduceMotion, true))
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
            .environment(\.accessibilityReduceMotion, true)
        let neutral = try await rendered(window) { pixel in
            max(pixel.x, pixel.y, pixel.z) - min(pixel.x, pixel.y, pixel.z) < 0.02
        }
        attach(neutral, name: "TV-Sports-background-empty")
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

    private func sample(_ image: UIImage) throws -> SIMD3<Double> {
        let cg = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: CGFloat(cg.width / 5), y: CGFloat(cg.height / 2), width: 1, height: 1)))
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
