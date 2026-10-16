import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

@MainActor
final class ToolbarLayoutTests: XCTestCase {
    func testToolbarWordsHaveTheirFullWidthAndRenderTheAppSurface() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        var widths: [String: CGFloat] = [:]
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            Color.black.navigationTitle("Catch Up").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    LineupToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {}.buttonStyle(LineupBarButtonStyle())
                            .background(GeometryReader { geometry in
                                Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in widths["Cancel"] = width }
                            })
                    }
                    LineupToolbarItem(placement: .confirmationAction) {
                        Button("Done") {}.buttonStyle(LineupBarButtonStyle(prominent: true))
                            .background(GeometryReader { geometry in
                                Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in widths["Done"] = width }
                            })
                    }
                }
        }.preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(widths["Cancel"]), 65, "Cancel must not be squeezed into a round icon-sized slot")
        XCTAssertGreaterThan(try XCTUnwrap(widths["Done"]), 55)
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Lineup-toolbar-Cancel-Done"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
