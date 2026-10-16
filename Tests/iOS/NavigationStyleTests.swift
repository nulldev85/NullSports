import XCTest
import UIKit
import SwiftUI
@testable import LineupiOS

final class NavigationStyleTests: XCTestCase {
    @MainActor
    func testReorderingBothBarsKeepsSelectionAndCustomTabActivationAligned() async throws {
        let defaults = UserDefaults.standard
        let previousOrder = defaults.object(forKey: MobileNavigationOrder.storageKey)
        defaults.set(MobileNavigationOrder.defaultValue, forKey: MobileNavigationOrder.storageKey)
        defer {
            if let previousOrder { defaults.set(previousOrder, forKey: MobileNavigationOrder.storageKey) }
            else { defaults.removeObject(forKey: MobileNavigationOrder.storageKey) }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let model = NavigationPreviewState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStylePreview(model: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(400))
        let tabs = try XCTUnwrap(Self.tabController(in: window.rootViewController))
        for (glass, order) in [(false, "0,1,2,4,3"), (false, "3,4,2,1,0"),
                               (true, "1,0,3,4,2"), (true, "3,4,2,1,0"), (false, "0,1,2,4,3")] {
            let selectionBeforeReordering = model.selection
            defaults.set(order, forKey: MobileNavigationOrder.storageKey)
            model.glass = glass
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            XCTAssertTrue(Self.tabController(in: window.rootViewController) === tabs)
            let arranged = MobileNavigationOrder.tabs(in: order)
            XCTAssertEqual(model.selection, selectionBeforeReordering)
            XCTAssertEqual(tabs.selectedIndex, arranged.firstIndex { $0.rawValue == selectionBeforeReordering })
            XCTAssertEqual(tabs.tabBar.items?.map { $0.title ?? "" }, arranged.map(\.title))
            let navigation = try XCTUnwrap(Self.navigation(in: window))
            for (index, destination) in arranged.enumerated() {
                navigation.activate(destination) { model.selection = destination.rawValue }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(model.selection, destination.rawValue)
                XCTAssertEqual(tabs.selectedIndex, index)
                XCTAssertNotNil(tabs.selectedViewController)
            }
        }
    }

    @MainActor
    func testCustomTabTapsReturnHomeAndPreserveNativeControllers() {
        let roots = MobileNavigationTab.allCases.map { _ in UIViewController() }
        let stacks = roots.map { UINavigationController(rootViewController: $0) }
        let tabs = UITabBarController()
        tabs.setViewControllers(stacks, animated: false)
        tabs.selectedIndex = 2
        let navigation = MobileTabNavigation()
        navigation.tabs = tabs
        var selection = 2
        for tab in [.library, .search, .settings, .sports, .guide, .library] as [MobileNavigationTab] {
            let index = MobileNavigationTab.allCases.firstIndex(of: tab)!
            stacks[index].pushViewController(UIViewController(), animated: false)
            navigation.activate(tab) { selection = tab.rawValue }
            XCTAssertEqual(selection, tab.rawValue)
            XCTAssertEqual(tabs.selectedIndex, index)
            XCTAssertEqual(stacks[index].viewControllers.count, 1)
            XCTAssertTrue(stacks[index].viewControllers.first === roots[index])
            XCTAssertTrue(tabs.viewControllers?[index] === stacks[index])
        }
    }

    @MainActor
    func testRetappingATabScrollsHomeWithoutMovingTheHorizontalPosition() {
        let root = UIViewController()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset.top = 20
        scroll.contentSize = CGSize(width: 1200, height: 2400)
        scroll.contentOffset = CGPoint(x: 160, y: 700)
        root.view = scroll
        let tabs = UITabBarController()
        tabs.setViewControllers([UINavigationController(rootViewController: root)], animated: false)
        let navigation = MobileTabNavigation()
        navigation.tabs = tabs
        navigation.activate(.sports) {}
        XCTAssertEqual(scroll.contentOffset.x, 160)
        XCTAssertEqual(scroll.contentOffset.y, -20)
    }

    @MainActor
    func testCustomRetapPopsARealSwiftUINavigationStackAndItsPath() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let model = NavigationRootPreviewState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationRootPreview(model: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(300))
        let tabs = try XCTUnwrap(Self.tabController(in: window.rootViewController))
        let navigation = try XCTUnwrap(Self.navigation(in: window))
        let selected = tabs.selectedViewController
        for (iteration, path) in [[1, 2], [3], [4, 5, 6]].enumerated() {
            model.path = path
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(model.path, path, "A new push must work after returning home")
            if iteration == 1 {
                navigation.activate(.search) { model.selection = 4 }
                try await Task.sleep(for: .milliseconds(200))
            }
            navigation.activate(.library) { model.selection = 2 }
            navigation.activate(.library) { model.selection = 2 }
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(model.path.isEmpty, "Returning home must update SwiftUI's path too")
            XCTAssertTrue(tabs.selectedViewController === selected)
        }
    }

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
    func testCustomAndGlassNavigationKeepControllersSelectionAndCaptureBothStyles() async throws {
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
            XCTAssertEqual(tabs.tabBar.isHidden, !(glass && MobileNavigationStyle.supportsGlass))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = glass && MobileNavigationStyle.supportsGlass
                ? "Native-Apple-Liquid-Glass-On" : "Lineup-Rectangular-Navigation-Off"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        // Both bars address the same TabView. Keep each destination's actual
        // controller alive while selecting in visual order (Search precedes
        // Settings even though their original numeric tags do not).
        var visited: [Int: UIViewController] = [2: selected]
        for glass in [false, true, false] {
            model.glass = glass
            for (index, destination) in MobileNavigationTab.allCases.enumerated() {
                model.selection = destination.rawValue
                try await Task.sleep(for: .milliseconds(150))
                window.layoutIfNeeded()
                XCTAssertTrue(Self.tabController(in: window.rootViewController) === tabs)
                XCTAssertEqual(tabs.selectedIndex, index)
                let controller = try XCTUnwrap(tabs.selectedViewController)
                if let previous = visited[destination.rawValue] { XCTAssertTrue(controller === previous) }
                visited[destination.rawValue] = controller
            }
            // The same visibility used by inline Sports and Guide playback.
            model.fullscreen = true
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            XCTAssertTrue(tabs.tabBar.isHidden)
            model.fullscreen = false
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            XCTAssertEqual(tabs.tabBar.isHidden, !(glass && MobileNavigationStyle.supportsGlass))
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

    @MainActor
    private static func navigation(in view: UIView) -> MobileTabNavigation? {
        if let probe = view as? MobileTabBarAppearance.Probe, let navigation = probe.navigation { return navigation }
        for child in view.subviews {
            if let navigation = navigation(in: child) { return navigation }
        }
        return nil
    }
}

@MainActor
private final class NavigationRootPreviewState: ObservableObject {
    @Published var selection = 2
    @Published var path: [Int] = []
}

private struct NavigationRootPreview: View {
    @ObservedObject var model: NavigationRootPreviewState
    var body: some View {
        TabView(selection: $model.selection) {
            ForEach(MobileNavigationTab.allCases) { tab in
                Group {
                    if tab == .library {
                        NavigationStack(path: $model.path) {
                            Text("Library home")
                                .navigationDestination(for: Int.self) { Text("Detail \($0)") }
                        }
                        .mobileTabHome(.library) { model.path = [] }
                    } else {
                        NavigationStack { Text(tab.title) }
                    }
                }
                .mobileNativeTabBar(liquidGlass: false)
                .tabItem { Label(tab.title, systemImage: "square") }.tag(tab.rawValue)
            }
        }
        .mobileNavigationChrome(selection: $model.selection, liquidGlass: false)
    }
}

@MainActor
private final class NavigationPreviewState: ObservableObject {
    @Published var glass = false
    @Published var selection = 2
    @Published var fullscreen = false
}

private struct NavigationStylePreview: View {
    @ObservedObject var model: NavigationPreviewState
    @AppStorage(MobileNavigationOrder.storageKey) private var order = MobileNavigationOrder.defaultValue

    var body: some View {
        TabView(selection: $model.selection) {
            ForEach(MobileNavigationOrder.tabs(in: order)) { tab in
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
                    .navigationTitle(tab.title)
                }
                .mobileNativeTabBar(liquidGlass: model.glass, fullscreen: model.fullscreen)
                .tabItem { Label { Text(tab.title) } icon: { tab.icon(selected: model.selection == tab.rawValue) } }
                .tag(tab.rawValue)
            }
        }
        .tint(.white).preferredColorScheme(.dark)
        .mobileNavigationChrome(selection: $model.selection, liquidGlass: model.glass, fullscreen: model.fullscreen)
    }
}
