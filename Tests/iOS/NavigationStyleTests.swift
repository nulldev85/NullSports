import XCTest
import UIKit
import SwiftUI
@testable import LineupiOS

final class NavigationStyleTests: XCTestCase {
    @MainActor
    func testSwitchingAppearancePreservesNativeNavigationAndFullscreenVisibility() {
        let bar = UITabBar(frame: CGRect(x: 0, y: 0, width: 390, height: 83))
        let items = ["Sports", "TV Guide", "Library", "Search", "Settings"].enumerated().map {
            UITabBarItem(title: $0.element, image: UIImage(systemName: "tv"), tag: $0.offset)
        }
        bar.items = items
        bar.selectedItem = items[2]
        bar.isHidden = true
        let originalFrame = bar.frame
        let style = MobileTabBarStyle()

        for glass in [false, true, false] {
            style.apply(to: bar, liquidGlass: glass)
            XCTAssertTrue(bar.selectedItem === items[2])
            XCTAssertEqual(bar.items?.count, items.count)
            for (actual, original) in zip(bar.items ?? [], items) { XCTAssertTrue(actual === original) }
            XCTAssertEqual(bar.frame, originalFrame)
            XCTAssertTrue(bar.isHidden, "A style switch must not reveal the fullscreen player's tab bar")
        }
        XCTAssertEqual(bar.standardAppearance.backgroundColor, UIColor(LineupStyle.background))
    }

    @MainActor
    func testGlassRestoresOriginalNativeAppearance() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Liquid Glass requires iOS 26") }
        let bar = UITabBar(frame: CGRect(x: 0, y: 0, width: 390, height: 83))
        let original = bar.standardAppearance.copy() as! UITabBarAppearance
        let originalEdge = bar.scrollEdgeAppearance?.copy() as? UITabBarAppearance
        let style = MobileTabBarStyle()
        style.apply(to: bar, liquidGlass: false)
        style.apply(to: bar, liquidGlass: true)
        XCTAssertEqual(bar.standardAppearance.backgroundColor, original.backgroundColor)
        XCTAssertEqual(bar.standardAppearance.backgroundImage, original.backgroundImage)
        XCTAssertEqual(bar.standardAppearance.shadowColor, original.shadowColor)
        XCTAssertEqual(bar.standardAppearance.backgroundEffect != nil, original.backgroundEffect != nil)
        XCTAssertEqual(bar.scrollEdgeAppearance != nil, originalEdge != nil)
        style.apply(to: bar, liquidGlass: true)
        XCTAssertEqual(bar.standardAppearance.backgroundColor, original.backgroundColor)
    }

    @MainActor
    func testNativeTabViewKeepsItsControllerAndSelectionAndCapturesBothStyles() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Liquid Glass requires iOS 26") }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("No iPhone scene for the navigation preview")
        }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let model = NavigationPreviewState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStylePreview(model: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let tabs = try XCTUnwrap(Self.tabController(in: window.rootViewController))
        let selected = try XCTUnwrap(tabs.selectedViewController)

        for glass in [false, true, false] {
            model.glass = glass
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            XCTAssertTrue(Self.tabController(in: window.rootViewController) === tabs)
            XCTAssertTrue(tabs.selectedViewController === selected)
            XCTAssertEqual(model.selection, 2)
            XCTAssertEqual(tabs.tabBar.items?.count, 5)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = glass ? "Native-Apple-Liquid-Glass-On" : "Solid-Navigation-Off"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private static func tabController(in controller: UIViewController?) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller?.children ?? [] {
            if let tabs = tabController(in: child) { return tabs }
        }
        return nil
    }
}

@MainActor
private final class NavigationPreviewState: ObservableObject {
    @Published var glass = false
    @Published var selection = 2
}

private struct NavigationStylePreview: View {
    @ObservedObject var model: NavigationPreviewState
    private let titles = ["Sports", "TV Guide", "Library", "Search", "Settings"]
    private let symbols = ["play.rectangle", "list.bullet.rectangle", "play.square.stack", "magnifyingglass", "person.crop.circle"]

    var body: some View {
        TabView(selection: $model.selection) {
            ForEach(titles.indices, id: \.self) { index in
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 20) {
                            ForEach(0..<8) { row in
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(LinearGradient(colors: [.blue.opacity(0.65), .purple.opacity(0.45)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(height: 130)
                                    .overlay(Text("Library shelf \(row + 1)").font(.inter(22, .bold)))
                            }
                        }.padding(20)
                    }
                    .background(LineupStyle.background)
                    .navigationTitle(titles[index])
                }
                .tabItem { Label(titles[index], systemImage: symbols[index]) }.tag(index)
            }
        }
        .tint(.white).preferredColorScheme(.dark)
        .background(MobileTabBarAppearance(liquidGlass: model.glass).frame(width: 0, height: 0))
    }
}
