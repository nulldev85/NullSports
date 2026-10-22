#if os(iOS)
import XCTest
import UIKit
import SwiftUI
@testable import LineupiOS

@MainActor
final class MobileWelcomeBackdropTests: XCTestCase {
    func testEveryPosterIsInTheBundleAndAllRowsHaveArtworkOnFirstLayout() {
        XCTAssertEqual(MobileWelcomePosterArtwork.images.count, 12)
        for image in MobileWelcomePosterArtwork.images {
            XCTAssertEqual(image.width, 342)
            XCTAssertEqual(image.height, 513)
        }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852),
                     CGSize(width: 430, height: 932), CGSize(width: 852, height: 393)] {
            let canvas = MobileWelcomePosterCanvas(frame: CGRect(origin: .zero, size: size))
            canvas.setNeedsLayout()
            canvas.layoutIfNeeded()
            XCTAssertEqual(canvas.rows.count, 6)
            var lastBottom: CGFloat = -.infinity
            for row in canvas.rows {
                XCTAssertTrue(row.viewport.masksToBounds)
                XCTAssertGreaterThan(row.viewport.frame.minY, lastBottom)
                lastBottom = row.viewport.frame.maxY
                let cards = row.track.sublayers ?? []
                XCTAssertGreaterThanOrEqual(cards.count, 36)
                XCTAssertTrue(cards.allSatisfy { $0.contents != nil }, "No placeholders, API request or image download")
                XCTAssertTrue(cards.allSatisfy { $0.masksToBounds && $0.frame.minY == 0 })
                XCTAssertNil(row.track.animation(forKey: MobileWelcomePosterCanvas.animationKey),
                             "An offscreen view keeps its complete artwork without running an animation")
            }
        }
    }

    func testNativeRowsMoveImmediatelyAndSurviveUpdatesPauseResizeAndRecreation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        var canvas = MobileWelcomePosterCanvas(frame: controller.view.bounds)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.setMotionEnabled(true)
        controller.view.addSubview(canvas)
        defer {
            canvas.setMotionEnabled(false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        try await assertMoving(canvas)
        attach(window, name: "Welcome-bundled-posters-first-launch")

        let starts = canvas.rows.map { $0.track.animation(forKey: MobileWelcomePosterCanvas.animationKey)?.beginTime }
        for _ in 0..<20 { canvas.setMotionEnabled(true) }
        XCTAssertEqual(canvas.rows.map { $0.track.animation(forKey: MobileWelcomePosterCanvas.animationKey)?.beginTime }, starts,
                       "Form updates cannot restart or freeze a row")

        canvas.setMotionEnabled(false)
        let paused = canvas.rows.map { $0.track.transform.m41 }
        XCTAssertTrue(canvas.rows.allSatisfy { $0.track.animationKeys()?.isEmpty ?? true })
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(canvas.rows.map { $0.track.transform.m41 }, paused)
        canvas.setMotionEnabled(true)
        try await assertMoving(canvas)

        canvas.frame.size.height -= 100
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        try await assertMoving(canvas)
        canvas.removeFromSuperview()
        XCTAssertTrue(canvas.rows.allSatisfy { $0.track.animationKeys()?.isEmpty ?? true })
        controller.view.addSubview(canvas)
        try await assertMoving(canvas)

        // A new owner models closing and reopening the welcome screen: no
        // network cache, stale SwiftUI state or old animation is needed.
        canvas.removeFromSuperview()
        canvas = MobileWelcomePosterCanvas(frame: controller.view.bounds)
        canvas.setMotionEnabled(true)
        controller.view.addSubview(canvas)
        window.layoutIfNeeded()
        XCTAssertEqual(canvas.rows.count, 6)
        XCTAssertTrue(canvas.rows.flatMap { $0.track.sublayers ?? [] }.allSatisfy { $0.contents != nil })
        try await assertMoving(canvas)
        attach(window, name: "Welcome-bundled-posters-reopened")
    }

    func testSwiftUIBridgeFillsTheScreenAndDoesNotRestartOnBodyUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: WelcomeBackdropHarness(active: true))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        let canvas = try XCTUnwrap(backdrop(in: host.view))
        XCTAssertEqual(canvas.bounds.width, window.bounds.width, accuracy: 1)
        XCTAssertEqual(canvas.bounds.height, window.bounds.height, accuracy: 1)
        try await assertMoving(canvas)
        let starts = canvas.rows.map { $0.track.animation(forKey: MobileWelcomePosterCanvas.animationKey)?.beginTime }
        host.rootView = WelcomeBackdropHarness(active: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(backdrop(in: host.view) === canvas)
        XCTAssertEqual(canvas.rows.map { $0.track.animation(forKey: MobileWelcomePosterCanvas.animationKey)?.beginTime }, starts)
        host.rootView = WelcomeBackdropHarness(active: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(canvas.rows.allSatisfy { $0.track.animationKeys()?.isEmpty ?? true })
        XCTAssertTrue(canvas.rows.flatMap { $0.track.sublayers ?? [] }.allSatisfy { $0.contents != nil })
        host.rootView = WelcomeBackdropHarness(active: true)
        try await assertMoving(canvas)
    }

    private func backdrop(in view: UIView) -> MobileWelcomePosterCanvas? {
        if let canvas = view as? MobileWelcomePosterCanvas { return canvas }
        for child in view.subviews {
            if let canvas = backdrop(in: child) { return canvas }
        }
        return nil
    }

    private func assertMoving(_ canvas: MobileWelcomePosterCanvas) async throws {
        try await Task.sleep(for: .milliseconds(100))
        let before = try presentationPositions(canvas)
        try await Task.sleep(for: .milliseconds(350))
        let after = try presentationPositions(canvas)
        XCTAssertEqual(before.count, 6)
        for index in before.indices {
            let delta = after[index] - before[index]
            if index.isMultiple(of: 2) { XCTAssertLessThan(delta, -2, "Row \(index) moves left") }
            else { XCTAssertGreaterThan(delta, 2, "Row \(index) moves right") }
            XCTAssertEqual(canvas.rows[index].track.transform.m42, 0, "Tracks cannot cross vertically")
        }
    }

    private func presentationPositions(_ canvas: MobileWelcomePosterCanvas) throws -> [CGFloat] {
        try canvas.rows.map { row in
            let layer = try XCTUnwrap(row.track.presentation(), "A mounted row must have a presentation layer")
            XCTAssertLessThanOrEqual(layer.transform.m41, 0)
            XCTAssertGreaterThanOrEqual(layer.transform.m41 + row.track.bounds.width, row.viewport.bounds.width)
            return layer.transform.m41
        }
    }

    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct WelcomeBackdropHarness: View {
    let active: Bool
    var body: some View {
        MobileWelcomePosterBackdrop(isActive: active)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}
#endif
