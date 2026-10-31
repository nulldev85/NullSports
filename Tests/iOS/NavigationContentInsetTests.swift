import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

@MainActor
final class NavigationContentInsetTests: XCTestCase {
    func testNativeBarClearanceIsNotReservedAgainWhenTheBarFades() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let root = UIViewController()
        root.tabBarItem = UITabBarItem(title: "Settings", image: nil, tag: 0)
        let navigation = UINavigationController(rootViewController: root)
        let tabs = UITabBarController()
        tabs.setViewControllers([navigation], animated: false)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()
        let original = navigation.additionalSafeAreaInsets.bottom
        let safeBottom = root.view.convert(root.view.safeAreaLayoutGuide.layoutFrame, to: window).maxY
        let insets = MobileNavigationContentInsets()
        defer { insets.restore() }
        for opacity in [CGFloat(1), 0, 1] {
            tabs.tabBar.alpha = opacity
            insets.apply(to: navigation, above: tabs.tabBar)
            window.layoutIfNeeded()
            XCTAssertEqual(navigation.additionalSafeAreaInsets.bottom, original, accuracy: 1,
                "The native tab container already reserves its bar, including while transparent")
            XCTAssertEqual(root.view.convert(root.view.safeAreaLayoutGuide.layoutFrame, to: window).maxY,
                safeBottom, accuracy: 1, "Fading the bar must leave the page's safe area unchanged")
        }
    }

    func testLateNavigationContainerTakesOverWithoutInheritingAnEarlyReservation() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let parent = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()
        let boundary = UIView(frame: CGRect(x: 0, y: window.bounds.maxY - 82,
                                           width: window.bounds.width, height: 62))
        window.addSubview(boundary)
        let insets = MobileNavigationContentInsets()
        defer { insets.restore() }

        // Reproduce the initial pass before SwiftUI installs NavigationStack.
        insets.apply(to: parent, above: boundary, onLayout: {})
        window.layoutIfNeeded()
        XCTAssertGreaterThan(parent.additionalSafeAreaInsets.bottom, 0)
        XCTAssertTrue(parent.view.subviews.isEmpty, "The fallback host must keep ownership of its view hierarchy")

        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        parent.addChild(navigation)
        navigation.view.frame = parent.view.bounds
        navigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.view.addSubview(navigation.view)
        navigation.didMove(toParent: parent)
        window.layoutIfNeeded()
        for _ in 0..<3 {
            insets.apply(to: parent, above: boundary, onLayout: {})
            window.layoutIfNeeded()
            XCTAssertEqual(parent.additionalSafeAreaInsets.bottom, 0, "The old recipient must release its reservation")
            XCTAssertEqual(root.view.convert(root.view.safeAreaLayoutGuide.layoutFrame, to: window).maxY,
                           boundary.frame.minY, accuracy: 1, "The late navigation container must reserve the bar exactly once")
        }
        insets.restore()
        XCTAssertEqual(parent.additionalSafeAreaInsets.bottom, 0)
        XCTAssertEqual(navigation.additionalSafeAreaInsets.bottom, 0)
    }

    func testMeasuredClearancePropagatesToPushedPagesAndRestoresExistingInsets() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let original = UIEdgeInsets(top: 5, left: 3, bottom: 7, right: 4)
        navigation.additionalSafeAreaInsets = original
        let parent = UIViewController()
        parent.addChild(navigation)
        parent.view.addSubview(navigation.view)
        navigation.view.frame = parent.view.bounds
        navigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        navigation.didMove(toParent: parent)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()
        let boundary = UIView(frame: CGRect(x: 0, y: window.bounds.maxY - 150, width: window.bounds.width, height: 80))
        window.addSubview(boundary)
        let insets = MobileNavigationContentInsets()
        for covered in [150.0, 180.0, 130.0, 150.0] {
            boundary.frame.origin.y = window.bounds.maxY - covered
            insets.apply(to: parent, above: boundary)
            window.layoutIfNeeded()
            XCTAssertEqual(root.view.convert(root.view.safeAreaLayoutGuide.layoutFrame, to: window).maxY,
                           boundary.frame.minY, accuracy: 1)
            XCTAssertEqual(navigation.additionalSafeAreaInsets.top, original.top)
            XCTAssertEqual(navigation.additionalSafeAreaInsets.left, original.left)
            XCTAssertEqual(navigation.additionalSafeAreaInsets.right, original.right)
        }
        let pushed = UIViewController()
        navigation.pushViewController(pushed, animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(pushed.view.convert(pushed.view.safeAreaLayoutGuide.layoutFrame, to: window).maxY,
                       boundary.frame.minY, accuracy: 1,
                       "A pushed Settings/Library page must inherit the navigation container's clearance")
        insets.restore()
        XCTAssertEqual(navigation.additionalSafeAreaInsets, original)
    }

    /// The four non-Guide layouts: Sports' nested viewport, Library's art
    /// extending above navigation, Search's searchable stack, and Settings'
    /// grouped list. They use the real navigation chrome and UIKit bridge.
    func testOtherTabLayoutsEndAboveNavigationAcrossStyleChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let model = TabInsetPreviewState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: TabInsetPreview(model: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        for glass in [false, true, false] {
            model.glass = glass
            for tab in [MobileNavigationTab.sports, .library, .search, .settings] {
                model.selection = tab.rawValue
                for _ in 0..<8 {
                    try await Task.sleep(for: .milliseconds(100))
                    window.layoutIfNeeded()
                }
                let tabs = try XCTUnwrap(tabController(in: window.rootViewController))
                let selected = try XCTUnwrap(tabs.selectedViewController)
                let scroll = try XCTUnwrap(verticalScroll(in: selected.view))
                let barTop: CGFloat
                if glass && MobileNavigationStyle.supportsGlass {
                    barTop = tabs.tabBar.convert(tabs.tabBar.bounds, to: window).minY
                } else {
                    let boundary = try XCTUnwrap(MobileLineupNavigationBoundary.find(in: window))
                    barTop = boundary.convert(boundary.bounds, to: window).minY
                    XCTAssertEqual(boundary.convert(boundary.bounds, to: window).maxY,
                                   window.bounds.maxY - (window.safeAreaInsets.bottom > 0 ? 20 : 8), accuracy: 1,
                                   "The compact panel must use the reference's lower floating position")
                }
                let usableBottom = scroll.convert(scroll.bounds, to: window).maxY - scroll.adjustedContentInset.bottom
                XCTAssertLessThanOrEqual(usableBottom, barTop + 1,
                    "\(tab.title), glass \(glass): last content must clear the bar; insets \(scroll.adjustedContentInset)")
                // Grouped lists may keep their own small outer content margin.
                let margin: CGFloat = tab == .settings ? 32 : 1
                XCTAssertGreaterThanOrEqual(usableBottom, barTop - margin,
                    "\(tab.title), glass \(glass): navigation coverage must not be counted twice")
                let end = max(-scroll.adjustedContentInset.top,
                              scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
                scroll.setContentOffset(CGPoint(x: 0, y: end), animated: false)
                let lastBottom = scroll.convert(CGPoint(x: 0, y: scroll.contentSize.height), to: window).y
                XCTAssertLessThanOrEqual(lastBottom, barTop + 1)
                let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: screenshot)
                attachment.name = "Tab-bottom-\(tab.title)-\(glass ? "glass" : "custom")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        model.fullscreen = true
        model.selection = MobileNavigationTab.sports.rawValue
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
        }
        XCTAssertNil(MobileLineupNavigationBoundary.find(in: window))
        let tabs = try XCTUnwrap(tabController(in: window.rootViewController))
        let selected = try XCTUnwrap(tabs.selectedViewController)
        let scroll = try XCTUnwrap(verticalScroll(in: selected.view))
        XCTAssertGreaterThanOrEqual(scroll.convert(scroll.bounds, to: window).maxY - scroll.adjustedContentInset.bottom,
                                    window.bounds.maxY - window.safeAreaInsets.bottom - 1,
                                    "Hiding navigation for playback must release its reserved space")
    }

    private func tabController(in controller: UIViewController?) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller?.children ?? [] { if let tabs = tabController(in: child) { return tabs } }
        return nil
    }

    private func verticalScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 150,
           scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
        for child in view.subviews { if let scroll = verticalScroll(in: child) { return scroll } }
        return nil
    }
}

@MainActor
private final class TabInsetPreviewState: ObservableObject {
    @Published var selection = MobileNavigationTab.sports.rawValue
    @Published var glass = false
    @Published var fullscreen = false
    @Published var query = ""
}

private struct TabInsetPreview: View {
    @ObservedObject var model: TabInsetPreviewState
    @AppStorage(MobileNavigationOrder.storageKey) private var order = MobileNavigationOrder.defaultValue

    var body: some View {
        TabView(selection: $model.selection) {
            ForEach(MobileNavigationOrder.tabs(in: order)) { tab in
                NavigationStack { page(tab) }
                    .mobileNativeTabBar(liquidGlass: model.glass, fullscreen: model.fullscreen)
                    .tabItem { Label(tab.title, systemImage: "square") }.tag(tab.rawValue)
            }
        }
        .mobileNavigationChrome(selection: $model.selection, liquidGlass: model.glass, fullscreen: model.fullscreen)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func page(_ tab: MobileNavigationTab) -> some View {
        switch tab {
        case .sports:
            GeometryReader { _ in
                VStack(spacing: 0) {
                    Text("Sports").frame(height: 110)
                    rows(tab)
                }
            }.toolbar(.hidden, for: .navigationBar)
        case .library:
            rows(tab).ignoresSafeArea(edges: .top)
                .toolbarBackground(.hidden, for: .navigationBar)
        case .search:
            rows(tab).navigationTitle("Search")
                .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always))
        case .settings:
            List { ForEach(0..<40) { row in Text("Settings row \(row)").frame(height: 56) } }
                .lineupSettingsList().navigationTitle("Settings")
        case .guide:
            rows(tab)
        }
    }

    private func rows(_ tab: MobileNavigationTab) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<40) { row in
                    Text("\(tab.title) row \(row)").frame(maxWidth: .infinity).frame(height: 56)
                        .background(row.isMultiple(of: 2) ? Color.blue.opacity(0.4) : Color.purple.opacity(0.4))
                }
            }
        }
    }
}
