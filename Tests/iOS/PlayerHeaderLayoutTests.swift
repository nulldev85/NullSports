import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

@MainActor
final class PlayerHeaderLayoutTests: XCTestCase {
    func testActionsAndWholeBadgesFitNarrowAndLandscapeHeaders() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        for width in [CGFloat(280), 355, 730] {
            let layout = HeaderMeasurements()
            let host = UIHostingController(rootView: HeaderFixture(measurements: layout).preferredColorScheme(.dark))
            parent.addChild(host)
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 240)
            host.view.autoresizingMask = []
            parent.view.addSubview(host.view)
            host.didMove(toParent: parent)
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            let buttons = try ["close", "channels", "pip", "expand"].map { try XCTUnwrap(layout.frames[$0]) }
            let badges = try (["engine", "live", "quality"] + HeaderFixture.formats).map { try XCTUnwrap(layout.frames[$0]) }
            for rect in buttons + badges {
                XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
                XCTAssertLessThanOrEqual(rect.maxX, width + 0.5)
                XCTAssertLessThanOrEqual(rect.maxY, host.view.bounds.height + 0.5)
            }
            for frames in [buttons, badges] {
                for first in frames.indices {
                    for second in frames.indices where second > first {
                        XCTAssertFalse(frames[first].intersects(frames[second]), "Player controls must not overlap")
                    }
                }
            }
            XCTAssertGreaterThan(badges.map(\.minY).min()!, buttons.map(\.maxY).max()!)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Player-header-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }
}

@MainActor
private final class HeaderMeasurements: ObservableObject {
    var frames: [String: CGRect] = [:]
}

private struct HeaderFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private extension View {
    func measureHeader(_ id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: HeaderFrames.self, value: [id: proxy.frame(in: .named("header"))])
            }
        }
    }
}

private struct HeaderFixture: View {
    static let formats = ["Dolby Vision", "Dolby Atmos", "HEVC", "59.94 fps"]
    let measurements: HeaderMeasurements
    var body: some View {
        MobilePlayerHeader {
            HStack(spacing: 8) {
                button("close", symbol: "xmark")
                Spacer(minLength: 8)
                button("channels", symbol: "list.bullet")
                button("pip", symbol: "pip.enter")
                button("expand", symbol: "arrow.up.left.and.arrow.down.right")
            }
        } details: {
            MobilePlaybackEngineBadge(engine: .aether).measureHeader("engine")
            Text("REPLAY · WED, OCT 14").font(.inter(.caption2, .bold)).fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 7).measureHeader("live")
            Text("1080p").font(.inter(.caption2, .semibold)).fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 7).measureHeader("quality")
            ForEach(Self.formats, id: \.self) { PlaybackFormatBadge(text: $0).measureHeader($0) }
        }
        .coordinateSpace(name: "header")
        .onPreferenceChange(HeaderFrames.self) { measurements.frames = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
    }
    private func button(_ id: String, symbol: String) -> some View {
        Button {} label: {
            Image(systemName: symbol).frame(width: 36, height: 36)
        }.buttonStyle(.plain).measureHeader(id)
    }
}
