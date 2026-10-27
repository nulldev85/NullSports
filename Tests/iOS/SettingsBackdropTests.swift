import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

/// Settings is the app's black, lit only by the accent's glow in the top
/// left, and that glow reaches the corner: no bar covers it, at rest or once
/// the rows have scrolled up under the title.
@MainActor
final class SettingsBackdropTests: XCTestCase {
    func testSettingsIsBlackWithTheAccentGlowUpBehindTheTitle() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let standard = UserDefaults.standard
        let savedAccent = standard.object(forKey: LineupAccent.storageKey)
        standard.set(LineupAccent.red.hex, forKey: LineupAccent.storageKey)
        defer {
            if let savedAccent { standard.set(savedAccent, forKey: LineupAccent.storageKey) }
            else { standard.removeObject(forKey: LineupAccent.storageKey) }
        }
        let suite = "SettingsBackdropTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            MobileAccountView(selectedTab: .constant(MobileNavigationTab.settings.rawValue))
                .environment(SportsLibrary(profileDefaults: defaults))
                .environment(MediaLibrary(defaults: defaults, trackingKey: { nil }))
                .environmentObject(CloudSettingsSync.shared)
                .preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await settle(window, passes: 8)

        let list = try XCTUnwrap(verticalScroll(in: window))
        let rest = -list.adjustedContentInset.top
        let end = max(rest, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height)
        for (name, offset) in [("top", 0.0), ("scrolled", 240.0), ("further", 560.0)] {
            list.setContentOffset(CGPoint(x: 0, y: min(rest + offset, end)), animated: false)
            try await settle(window, passes: 4)
            let format = UIGraphicsImageRendererFormat()
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Settings-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let corner = try color(in: image, at: CGPoint(x: window.bounds.width * 0.1, y: 10))
            XCTAssertGreaterThan(corner.red - corner.green, 0.08,
                                 "\(name): the accent's glow must reach the top left, with no bar over it")
            // The margin beside the rows, low on the far side: only black.
            let side = try color(in: image, at: CGPoint(x: window.bounds.width - 4, y: window.bounds.height * 0.62))
            XCTAssertLessThan(side.blue - side.red, 0.02, "\(name): the ground must be black, not blue")
            XCTAssertLessThan(side.red, 0.06, "\(name): the ground must be black")
        }
    }

    private func settle(_ window: UIWindow, passes: Int) async throws {
        for _ in 0..<passes {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
        }
    }

    private func color(in image: UIImage, at point: CGPoint) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Core Graphics counts rows up from the bottom.
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    private func verticalScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 150,
           scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
        for child in view.subviews { if let scroll = verticalScroll(in: child) { return scroll } }
        return nil
    }
}
