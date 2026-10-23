import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

final class NavigationScrollTests: XCTestCase {
    func testDirectionHysteresisHorizontalScrollingAndReversals() {
        var direction = MobileNavigationScrollDirection()
        XCTAssertNil(direction.sample(translation: CGPoint(x: 0, y: -5), distanceFromTop: 100))
        XCTAssertNil(direction.sample(translation: CGPoint(x: 0, y: -16), distanceFromTop: 111))
        XCTAssertEqual(direction.sample(translation: CGPoint(x: 0, y: -42), distanceFromTop: 137), true)
        XCTAssertNil(direction.sample(translation: CGPoint(x: 0, y: -39), distanceFromTop: 134))
        XCTAssertEqual(direction.sample(translation: CGPoint(x: 0, y: -28), distanceFromTop: 123), false,
                       "A reversal should expand during the same drag, without undoing the full downward distance")

        var sideways = MobileNavigationScrollDirection()
        XCTAssertNil(sideways.sample(translation: CGPoint(x: -30, y: -9), distanceFromTop: 100))
        XCTAssertNil(sideways.sample(translation: CGPoint(x: -90, y: -50), distanceFromTop: 140),
                     "A horizontal shelf or timeline gesture must not become a navigation gesture")
        var top = MobileNavigationScrollDirection()
        XCTAssertEqual(top.sample(translation: CGPoint(x: 0, y: -40), distanceFromTop: 0), false)
        XCTAssertEqual(top.sample(translation: CGPoint(x: 0, y: 25), distanceFromTop: -25), false,
                       "Pull-to-refresh at the beginning keeps the full bar")
    }

    @MainActor
    func testScrollingMorphsToSportsAndBackWithoutReplacingThePageOrMovingIt() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let model = ScrollNavigationPreviewState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ScrollNavigationPreview(model: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await settle { Self.find(MobileTabBarAppearance.Probe.self, in: window)?.navigation?.tabs != nil }
        let navigation = try XCTUnwrap(Self.find(MobileTabBarAppearance.Probe.self, in: window)?.navigation)
        let tabs = try XCTUnwrap(navigation.tabs)
        let page = try XCTUnwrap(tabs.selectedViewController)

        for glass in [false, true, false] {
            model.glass = glass
            try await settle { tabs.tabBar.isHidden == !(glass && MobileNavigationStyle.supportsGlass) }
            let scroll = try XCTUnwrap(Self.find(NavigationGestureScroll.self, in: page.view))
            scroll.setContentOffset(CGPoint(x: 0, y: 320), animated: false)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertFalse(navigation.isCompact, "Programmatic scrolls must not collapse navigation")
            let delegate = scroll.delegate
            let gestures = scroll.gestureRecognizers?.count
            navigation.scrollObservation.discoverScrollViews(from: scroll)
            XCTAssertTrue(scroll.delegate === delegate)
            XCTAssertEqual(scroll.gestureRecognizers?.count, gestures,
                           "Scrolling keeps the scroll view's own recognizers and delegate")
            navigation.scrollObservation.receivePanInput(from: scroll, phase: .began, translation: .zero)
            scroll.contentOffset.y = 380
            navigation.scrollObservation.receivePanInput(from: scroll, phase: .changed,
                                                         translation: CGPoint(x: 0, y: -60))
            try await settle {
                guard let boundary = MobileLineupNavigationBoundary.find(in: window) else { return false }
                return navigation.isCompact && abs(boundary.bounds.width - 62) < 1 && tabs.tabBar.isHidden
            }
            let boundary = try XCTUnwrap(MobileLineupNavigationBoundary.find(in: window))
            let frame = boundary.convert(boundary.bounds, to: window)
            XCTAssertEqual(frame.minX, 20, accuracy: 1)
            XCTAssertEqual(frame.height, 62, accuracy: 1)
            XCTAssertEqual(frame.maxY, window.bounds.maxY - (window.safeAreaInsets.bottom > 0 ? 20 : 8), accuracy: 1)
            try await settle {
                let usableBottom = scroll.convert(scroll.bounds, to: window).maxY - scroll.adjustedContentInset.bottom
                return usableBottom <= frame.minY + 1
            }
            XCTAssertEqual(scroll.contentOffset.y, 380, accuracy: 1, "Compacting must not jump the list")
            XCTAssertTrue(tabs.selectedViewController === page)
            XCTAssertEqual(model.selection, MobileNavigationTab.library.rawValue)
            XCTAssertEqual(tabs.tabBar.items?.count, 5)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Scroll-navigation-Sports-only-\(glass ? "glass" : "solid")"
            attachment.lifetime = .keepAlways
            add(attachment)

            scroll.contentOffset.y = 362
            navigation.scrollObservation.receivePanInput(from: scroll, phase: .changed,
                                                         translation: CGPoint(x: 0, y: -42))
            try await settle {
                guard !navigation.isCompact else { return false }
                if glass && MobileNavigationStyle.supportsGlass { return !tabs.tabBar.isHidden }
                return (MobileLineupNavigationBoundary.find(in: window)?.bounds.width ?? 0) > 250
            }
            XCTAssertEqual(scroll.contentOffset.y, 362, accuracy: 1, "Expanding must preserve the browsed position")
            XCTAssertTrue(tabs.selectedViewController === page)
            navigation.scrollObservation.receivePanInput(from: scroll, phase: .ended,
                                                         translation: CGPoint(x: 0, y: -42))
        }

        let scroll = try XCTUnwrap(Self.find(NavigationGestureScroll.self, in: page.view))
        collapse(navigation.scrollObservation, scroll: scroll)
        XCTAssertTrue(navigation.isCompact)
        // The small Sports button uses this same existing activation path.
        navigation.activate(.sports) { model.selection = MobileNavigationTab.sports.rawValue }
        try await settle { !navigation.isCompact && model.selection == MobileNavigationTab.sports.rawValue }
        XCTAssertTrue(tabs.viewControllers?.contains { $0 === page } == true)
    }

    @MainActor
    func testObserverIgnoresShelvesInactivePagesKeyboardAndFullscreen() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let root = UIViewController()
        let other = UIViewController()
        let tabs = UITabBarController()
        tabs.setViewControllers([root, other], animated: false)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()
        let vertical = NavigationGestureScroll(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        vertical.contentSize = CGSize(width: 390, height: 2_400)
        root.view.addSubview(vertical)
        let shelf = NavigationGestureScroll(frame: CGRect(x: 0, y: 0, width: 390, height: 180))
        shelf.contentSize = CGSize(width: 2_400, height: 180)
        shelf.contentInsetAdjustmentBehavior = .never
        vertical.addSubview(shelf)
        let observer = MobileNavigationScrollObserver()
        observer.update(tabs: tabs, selection: 0, enabled: true)
        defer { observer.detach() }
        collapse(observer, scroll: shelf)
        XCTAssertFalse(observer.isCompact, "A poster shelf has no vertical scroll range")
        collapse(observer, scroll: vertical)
        XCTAssertTrue(observer.isCompact)
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        XCTAssertFalse(observer.isCompact)
        collapse(observer, scroll: vertical)
        XCTAssertFalse(observer.isCompact, "Editing must keep every tab available")
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        collapse(observer, scroll: vertical)
        XCTAssertTrue(observer.isCompact)
        observer.update(tabs: tabs, selection: 0, enabled: false)
        XCTAssertFalse(observer.isCompact, "Fullscreen/background entry resets navigation")
        collapse(observer, scroll: vertical)
        XCTAssertFalse(observer.isCompact)
        observer.update(tabs: tabs, selection: 0, enabled: true)
        tabs.selectedIndex = 1
        observer.update(tabs: tabs, selection: 1, enabled: true)
        collapse(observer, scroll: vertical)
        XCTAssertFalse(observer.isCompact, "A retained inactive tab cannot hide the current tab's navigation")
    }

    @MainActor private func collapse(_ observer: MobileNavigationScrollObserver, scroll: NavigationGestureScroll) {
        observer.discoverScrollViews(from: scroll)
        scroll.contentOffset.y = 200
        observer.receivePanInput(from: scroll, phase: .began, translation: .zero)
        scroll.contentOffset.y = 260
        observer.receivePanInput(from: scroll, phase: .changed, translation: CGPoint(x: 0, y: -60))
    }

    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Navigation did not reach its expected presentation")
    }

    @MainActor private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }
}

/// Deterministic pan input drives the production observer while the real
/// hierarchy owns scrolling, layout, safe areas and native tab visibility.
@MainActor private final class NavigationGestureScroll: UIScrollView {}

@MainActor private final class ScrollNavigationPreviewState: ObservableObject {
    @Published var glass = false
    @Published var selection = MobileNavigationTab.library.rawValue
}

private struct ScrollNavigationPreview: View {
    @ObservedObject var model: ScrollNavigationPreviewState
    @AppStorage(MobileNavigationOrder.storageKey) private var order = MobileNavigationOrder.defaultValue
    var body: some View {
        TabView(selection: $model.selection) {
            ForEach(MobileNavigationOrder.tabs(in: order)) { tab in
                NavigationStack {
                    ScrollNavigationFixture().navigationTitle(tab.title)
                }
                .mobileNativeTabBar(liquidGlass: model.glass)
                .tabItem { Label(tab.title, systemImage: "square") }.tag(tab.rawValue)
            }
        }
        .mobileNavigationChrome(selection: $model.selection, liquidGlass: model.glass)
        .environment(\.scenePhase, .active)
        .preferredColorScheme(.dark)
    }
}

private struct ScrollNavigationFixture: UIViewRepresentable {
    func makeUIView(context: Context) -> NavigationGestureScroll {
        let scroll = NavigationGestureScroll()
        scroll.contentSize = CGSize(width: 300, height: 2_400)
        let label = UILabel(frame: CGRect(x: 20, y: 300, width: 250, height: 80))
        label.text = "Library rows"
        scroll.addSubview(label)
        return scroll
    }
    func updateUIView(_ view: NavigationGestureScroll, context: Context) {}
}
