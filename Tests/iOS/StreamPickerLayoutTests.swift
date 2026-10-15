import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

@MainActor
final class StreamPickerLayoutTests: XCTestCase {
    /// Save real layouts for the compact menu, long names, landscape, and the
    /// source filter. No server connection or playable external URL is needed.
    func testStreamPickerCapturesCompactAndLongResultsAtPhoneSizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        var vod = try source(id: "vod", name: "Marshals S02E01 · All Hat No Cattle")
        vod.directURL = URL(string: "https://example.invalid/episode.mp4")
        var server = try source(id: "server", name: "Marshals.S02E01.2160p.WEB-DL.Dolby.Vision.HDR10.HEVC.TrueHD.Atmos.7.1.Very.Long.Release.Name.mkv")
        server.serverName = "Nullfin"
        let statuses = [StreamServerStatus(id: UUID(), name: "VOD", phase: .found(1)),
                        StreamServerStatus(id: UUID(), name: "Nullfin", phase: .found(1)),
                        StreamServerStatus(id: UUID(), name: "Another Media Server", phase: .looking)]
        for (name, size, sources, filter) in [
            ("compact-one-result", CGSize(width: 320, height: 568), [vod], nil as String?),
            ("long-results", CGSize(width: 393, height: 852), [vod, server], nil),
            ("landscape-filter", CGSize(width: 730, height: 350), [vod, server], "Nullfin")
        ] {
            let board = MobileStreamPickerBoard(
                heading: MediaStreamHeading(title: "Marshals", subtitle: "S02E01 · All Hat No Cattle", backdrop: nil),
                statuses: statuses, sources: sources, loading: true, error: nil,
                filter: .constant(filter), choose: { _ in }, cancel: {})
                .preferredColorScheme(.dark)
            let host = UIHostingController(rootView: board)
            parent.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.autoresizingMask = []
            parent.view.addSubview(host.view)
            host.didMove(toParent: parent)
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Stream-picker-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(image.size, size)
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }

    private func source(id: String, name: String) throws -> MediaPlaybackSource {
        let json = try JSONSerialization.data(withJSONObject: ["Id": id, "Name": name, "Container": "mkv"])
        return try JSONDecoder().decode(MediaPlaybackSource.self, from: json)
    }
}
