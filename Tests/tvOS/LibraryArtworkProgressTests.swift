import SwiftUI
import UIKit
import XCTest
@testable import Lineup

@MainActor
final class LibraryArtworkProgressTests: XCTestCase {
    func testRestoredEpisodeAndMovieProgressRendersOverCroppedArtwork() async throws {
        let suite = "LibraryArtworkProgressTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = MediaServerProfile(name: "Jellyfin", serverURL: "https://server.invalid",
            username: "viewer", userID: "user")
        let provider = XtreamProfile(name: "Provider", serverURL: "https://provider.invalid", username: "viewer")
        defaults.set(try JSONEncoder().encode([server]), forKey: "NullSports.mediaServers")
        defaults.set(try JSONEncoder().encode([provider]), forKey: "NullSports.profiles")
        defaults.set(provider.id.uuidString, forKey: "NullSports.activeProfile")

        // Keep pixel assertions independent of any accent another test left in
        // standard defaults. Restore the user's/test host's exact value below.
        let previousAccent = UserDefaults.standard.object(forKey: LineupAccent.storageKey)
        UserDefaults.standard.set(LineupAccent.red.hex, forKey: LineupAccent.storageKey)
        defer {
            if let previousAccent { UserDefaults.standard.set(previousAccent, forKey: LineupAccent.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: LineupAccent.storageKey) }
        }

        for vod in [false, true] {
            let source = vod ? provider.id : server.id
            let episode = MediaItem(id: vod ? "iptv:episode:42:1" : "episode", name: "The Wire",
                type: "Episode", overview: nil, productionYear: nil, primaryImageAspectRatio: nil,
                childCount: nil, indexNumber: 1, parentIndexNumber: 1,
                seriesName: "The Wire", seriesID: vod ? "iptv:series:42" : "wire").servedBy(source)
            let movie = MediaItem(id: vod ? "iptv:movie:43" : "movie", name: "Movie", type: "Movie",
                overview: nil, productionYear: nil, primaryImageAspectRatio: nil, childCount: nil).servedBy(source)
            let media = MediaLibrary(defaults: defaults)
            media.trackPlayback(of: episode, position: 900, duration: 3_600)
            media.trackPlayback(of: movie, position: 600, duration: 2_400)
            media.flushLocalPlayback()
            let restored = MediaLibrary(defaults: defaults)

            for item in [episode, movie] {
                let playback = try XCTUnwrap(restored.cardPlayback(for: item, asShow: false))
                XCTAssertEqual(playback.fraction, 0.25)
                XCTAssertEqual(restored.resumePosition(for: item), item.type == "Episode" ? 900 : 600)
                // A portrait source in a still used to position the overlay
                // below the card; a wide source in a poster put it off the side.
                for (name, imageSize, cardSize) in [
                    ("portrait-in-still", CGSize(width: 600, height: 900), CGSize(width: 400, height: 225)),
                    ("wide-in-poster", CGSize(width: 1600, height: 900), CGSize(width: 220, height: 330)),
                    ("matching-still", CGSize(width: 1600, height: 900), CGSize(width: 400, height: 225))
                ] {
                    let image = try await render(playback: playback, imageSize: imageSize, cardSize: cardSize)
                    let bottom = CGRect(x: 0, y: cardSize.height - 85, width: cardSize.width, height: 85)
                    let ink = try XCTUnwrap(accentBounds(in: image, region: bottom),
                        "\(name): the progress fill must be visible at the foot of the thumbnail")
                    XCTAssertGreaterThan(ink.width, 3)
                    XCTAssertLessThan(ink.width, cardSize.width * 0.5, "A quarter played cannot fill the whole card")
                    XCTAssertGreaterThan(ink.minX, 0)
                    XCTAssertLessThan(ink.maxX, cardSize.width)
                    attach(image, name: "\(vod ? "VOD" : "Jellyfin")-\(item.type)-\(name)")
                }
            }
        }
    }

    func testShowPosterKeepsTheCurrentEpisodeBarAtTheVisibleBottomEdge() async throws {
        let previousAccent = UserDefaults.standard.object(forKey: LineupAccent.storageKey)
        UserDefaults.standard.set(LineupAccent.red.hex, forKey: LineupAccent.storageKey)
        defer {
            if let previousAccent { UserDefaults.standard.set(previousAccent, forKey: LineupAccent.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: LineupAccent.storageKey) }
        }
        let playback = MediaCardPlayback(fraction: 0.4, label: "8 of 20", watched: false,
            episodeFraction: 0.25, spoken: "Episode 8 of 20")
        let image = try await render(playback: playback, imageSize: CGSize(width: 1600, height: 900),
            cardSize: CGSize(width: 220, height: 330))
        let edge = CGRect(x: 18, y: 327, width: 184, height: 3)
        XCTAssertNotNil(accentBounds(in: image, region: edge),
            "The episode bar belongs to the visible card's bottom edge")
        attach(image, name: "show-poster-current-episode-progress")
    }

    private func render(playback: MediaCardPlayback, imageSize: CGSize, cardSize: CGSize) async throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let artwork = UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: imageSize))
        }
        let laidOut = expectation(description: "visible thumbnail has its final size")
        var reported = false
        let card = TVMediaArtwork(playback: playback) {
            Image(uiImage: artwork).resizable().scaledToFill()
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                    if size == cardSize, !reported { reported = true; laidOut.fulfill() }
                }
            }
        }
        .ignoresSafeArea()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let host = UIHostingController(rootView: card)
        parent.addChild(host)
        host.view.frame = CGRect(origin: .zero, size: cardSize)
        host.view.autoresizingMask = []
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
        defer {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        await fulfillment(of: [laidOut], timeout: 5)
        host.view.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: cardSize, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    private func accentBounds(in image: UIImage, region: CGRect) -> CGRect? {
        guard let cgImage = image.cgImage?.cropping(to: region) else { return nil }
        let width = cgImage.width, height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if rgba[offset] > 215, rgba[offset + 1] < 105, rgba[offset + 2] < 125 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = "Library-progress-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
