import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

final class GuideScrollLayoutTests: XCTestCase {
    @MainActor
    func testGuideDoesNotDoubleApplyNavigationInsets() {
        let vertical = UIScrollView()
        MobileGuideScrollConfiguration.configure(vertical, horizontal: false)
        XCTAssertEqual(vertical.contentInsetAdjustmentBehavior, .never)
        XCTAssertTrue(vertical.bounces)
        XCTAssertTrue(vertical.isDirectionalLockEnabled)
        let horizontal = UIScrollView()
        MobileGuideScrollConfiguration.configure(horizontal, horizontal: true)
        XCTAssertEqual(horizontal.contentInsetAdjustmentBehavior, .never)
        XCTAssertFalse(horizontal.bounces)
    }

    @MainActor
    func testFavoritesResetTokenMovesTheActualScrollViewToItsTop() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let page = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()

        let scroll = UIScrollView(frame: page.view.bounds)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.contentSize = CGSize(width: page.view.bounds.width, height: 2_400)
        page.view.addSubview(scroll)
        let probe = MobileGuideScrollConfiguration.Probe(frame: CGRect(origin: .zero, size: scroll.contentSize))
        probe.horizontal = false
        probe.usesLineupNavigation = false
        var measured: CGFloat?
        probe.onBottomOverlap = { measured = $0 }
        scroll.addSubview(probe)
        try await settle { measured != nil }

        scroll.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
        XCTAssertEqual(scroll.contentOffset.y, 450, "The test must begin below the first favorite")
        probe.resetToken = UUID()
        probe.requestRefresh()
        try await settle { abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) < 0.5 }
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top,
                       "A guide data/order reset must place the real list viewport at its first row")
    }

    @MainActor
    func testFavoritesReserveVisibleNavigationBarOverlapAboveFirstRow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let page = UIViewController()
        page.view.backgroundColor = .black
        let navigation = UINavigationController(rootViewController: page)
        navigation.navigationBar.isHidden = false
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()
        navigation.view.layoutIfNeeded()

        // Model List mode's scroll view extending behind the translucent
        // navigation header. The first channel must begin below that header.
        let scroll = UIScrollView(frame: navigation.view.bounds)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.contentSize = CGSize(width: scroll.bounds.width, height: 2_400)
        navigation.view.addSubview(scroll)
        let probe = MobileGuideScrollConfiguration.Probe(frame: CGRect(origin: .zero, size: scroll.contentSize))
        probe.horizontal = false
        var measuredTop: CGFloat?
        probe.onTopOverlap = { measuredTop = $0 }
        scroll.addSubview(probe)
        try await settle { measuredTop != nil }

        let overlap = try XCTUnwrap(measuredTop)
        let bar = navigation.navigationBar
        let barBottom = bar.convert(bar.bounds, to: window).maxY
        let scrollTop = scroll.convert(scroll.bounds, to: window).minY
        XCTAssertGreaterThan(overlap, 0, "The fixture must overlap the visible navigation header")
        XCTAssertEqual(overlap, barBottom - scrollTop, accuracy: 1)

        // This is the scroll-content top margin applied by List mode.
        scroll.contentInset.top = overlap + MobileGuideLayoutMetrics.listFirstRowTopInset
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        let firstRowTop = scrollTop + scroll.adjustedContentInset.top
        XCTAssertEqual(firstRowTop, barBottom + MobileGuideLayoutMetrics.listFirstRowTopInset, accuracy: 1,
                       "The first favorite must begin below the entire navigation header")
    }

    @MainActor
    func testFavoritesListPlacesItsFirstRowBelowTheLiveNavigationHeader() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let model = GuideTopReservationTestState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: GuideTopReservationHarness(model: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await settle { model.firstRowFrame != nil && window.firstSubview(of: UINavigationBar.self) != nil }
        let bar = try XCTUnwrap(window.firstSubview(of: UINavigationBar.self) {
            !$0.isHidden && $0.alpha > 0.01
        })
        try await settle {
            guard let rowTop = model.firstRowFrame?.minY else { return false }
            let barBottom = bar.convert(bar.bounds, to: window).maxY
            return abs(rowTop - barBottom - MobileGuideLayoutMetrics.listFirstRowTopInset) < 3
        }
        window.layoutIfNeeded()
        let rowTop = try XCTUnwrap(model.firstRowFrame?.minY)
        let barBottom = bar.convert(bar.bounds, to: window).maxY
        XCTAssertGreaterThan(rowTop, barBottom,
                             "The first favorite row must not start beneath the Guide toolbar")
        XCTAssertEqual(rowTop, barBottom + MobileGuideLayoutMetrics.listFirstRowTopInset, accuracy: 3,
                       "List mode should preserve its designed top gap after clearing the toolbar")

        let probe = try XCTUnwrap(window.firstSubview(of: MobileGuideScrollConfiguration.Probe.self) {
            !$0.horizontal
        })
        let scroll = try XCTUnwrap(probe.enclosingScrollView)
        XCTAssertGreaterThan(scroll.contentSize.height, 1_000,
                             "The Guide probe must belong to the full-height favorites scroller")
        scroll.setContentOffset(CGPoint(x: 0, y: 320), animated: false)
        try await settle { (model.firstRowFrame?.minY ?? rowTop) < rowTop - 200 }
        model.resetToken = UUID()
        try await settle { abs((model.firstRowFrame?.minY ?? 0) - rowTop) < 3 }
        XCTAssertEqual(model.firstRowFrame?.minY ?? 0, rowTop, accuracy: 3,
                       "Refreshing favorites must recreate the real list at its first channel")
    }

    /// Scrolled to the end, the last channel rests right on top of the tab
    /// bar: not under it, and not with a gap above it. Built the way the TV
    /// Guide tab is, a vertical list inside the horizontal timeline, inside a
    /// navigation stack, inside the tab bar.
    @MainActor
    func testTheListsEndStaysReachableInBothNavigationStyles() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("No screen to lay the guide out on")
        }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let model = GuideNavigationTestState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: GuideEndHarness(model: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        // Time for the measured Guide viewport to settle.
        for glass in [false, true, false, true, false] {
            model.glass = glass
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                window.layoutIfNeeded()
            }
            let probe = try XCTUnwrap(window.firstSubview(of: MobileGuideScrollConfiguration.Probe.self) { !$0.horizontal })
            let list = try XCTUnwrap(probe.enclosingScrollView)
            let barTop: CGFloat
            if glass && MobileNavigationStyle.supportsGlass {
                let bar = try XCTUnwrap(window.firstSubview(of: UITabBar.self) { !$0.isHidden })
                barTop = bar.convert(bar.bounds, to: window).minY
            } else {
                // The compact custom bar floats into the bottom container
                // area; the Guide must stop at its actual top edge.
                let boundary = try XCTUnwrap(MobileLineupNavigationBoundary.find(in: window))
                barTop = boundary.convert(boundary.bounds, to: window).minY
                XCTAssertGreaterThan(barTop, 0)
                let bottomGap: CGFloat = window.safeAreaInsets.bottom > 0 ? 20 : 8
                XCTAssertLessThan(barTop, window.bounds.maxY - bottomGap - 44)
            }
            // Native glass can extend UIKit's actual scroller below the
            // proposed SwiftUI frame. The shared channel scroller reserves
            // its measured navigation coverage as a bottom content margin.
            let usableBottom = list.convert(list.bounds, to: window).maxY - list.adjustedContentInset.bottom
            XCTAssertEqual(usableBottom, barTop, accuracy: 1,
                           "glass \(glass), usable list edge must meet navigation; inset \(list.adjustedContentInset), "
                           + "measured clearance \(String(describing: probe.reported)), "
                           + "current overlap \(MobileGuideScrollConfiguration.bottomOverlap(of: list))")
            let end = list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height
            list.setContentOffset(CGPoint(x: list.contentOffset.x, y: end), animated: false)
            let lastRowBottom = list.convert(CGPoint(x: 0, y: list.contentSize.height), to: window).y
            XCTAssertEqual(lastRowBottom, barTop, accuracy: 1,
                           "glass \(glass), list ends at \(list.convert(list.bounds, to: window).maxY), "
                           + "insets \(list.adjustedContentInset), overlap \(MobileGuideScrollConfiguration.bottomOverlap(of: list))")
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "Guide-last-row-\(glass ? "glass" : "custom")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Build 97 observed an 83pt measurement after the bar moved to cover
    /// 118pt. Moving the custom bar alone must invalidate the Guide, even
    /// when neither the tall content nor its viewport needs layout.
    @MainActor
    func testCustomBarMovementRemeasuresAnUnchangedGuideViewport() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let page = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        window.layoutIfNeeded()
        let scroll = UIScrollView(frame: page.view.bounds)
        scroll.contentSize = CGSize(width: scroll.bounds.width, height: 2_400)
        page.view.addSubview(scroll)
        let boundary = MobileLineupNavigationBoundary.Boundary(frame:
            CGRect(x: 0, y: window.bounds.maxY - 83, width: window.bounds.width, height: 83))
        window.addSubview(boundary)
        let probe = MobileGuideScrollConfiguration.Probe(frame: CGRect(origin: .zero, size: scroll.contentSize))
        probe.usesLineupNavigation = true
        var reported: CGFloat?
        var deliveries = 0
        probe.onBottomOverlap = { overlap in
            reported = overlap
            deliveries += 1
            scroll.contentInset.bottom = overlap
        }
        scroll.addSubview(probe)
        try await settle { reported == 83 }
        let originalViewport = scroll.frame
        let originalContent = probe.frame
        for overlap in [CGFloat(118), 83, 135, 118] {
            boundary.frame.origin.y = window.bounds.maxY - overlap
            // Do not ask the scroll/probe to refresh or lay out. Its only
            // new input is the real boundary's position-change event.
            try await settle { reported == overlap }
            XCTAssertEqual(scroll.frame, originalViewport)
            XCTAssertEqual(probe.frame, originalContent)
            let usableBottom = scroll.convert(scroll.bounds, to: window).maxY - scroll.adjustedContentInset.bottom
            XCTAssertEqual(usableBottom, boundary.frame.minY, accuracy: 1)
            let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            scroll.setContentOffset(CGPoint(x: 0, y: end), animated: false)
            XCTAssertEqual(scroll.convert(CGPoint(x: 0, y: scroll.contentSize.height), to: window).y,
                           boundary.frame.minY, accuracy: 1)
        }
        boundary.removeFromSuperview()
        try await settle { reported == window.safeAreaInsets.bottom.rounded() }
        probe.removeFromSuperview()
        let detachedDeliveries = deliveries
        window.addSubview(boundary)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(deliveries, detachedDeliveries, "A detached Guide must stop observing navigation changes")
    }

    @MainActor
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "The Guide did not receive the changed navigation coverage", file: file, line: line)
        if !condition() { throw NSError(domain: "GuideScrollLayoutTests", code: 1) }
    }

    /// A native bar can finish appearing after the content probe's update.
    /// The tall content need not resize; its separate viewport observer must
    /// follow bar visibility, including while content is scrolled to the end.
    @MainActor
    func testNativeBarVisibilityRemeasuresTheGuideAfterItsInitialLayout() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native glass requires iOS 26") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let page = UIViewController()
        page.extendedLayoutIncludesOpaqueBars = true
        page.tabBarItem = UITabBarItem(title: "TV Guide", image: UIImage(systemName: "tv"), tag: 1)
        let tabs = UITabBarController()
        tabs.setViewControllers([page], animated: false)
        tabs.setTabBarHidden(true, animated: false)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded()
        let scroll = UIScrollView(frame: page.view.bounds)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.contentSize = CGSize(width: page.view.bounds.width, height: 2_400)
        page.view.addSubview(scroll)
        let probe = MobileGuideScrollConfiguration.Probe(frame: CGRect(origin: .zero, size: scroll.contentSize))
        probe.usesLineupNavigation = false
        var reported: CGFloat?
        probe.onBottomOverlap = { reported = $0 }
        scroll.addSubview(probe)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
        }
        XCTAssertNotNil(reported)
        scroll.setContentOffset(CGPoint(x: 0, y: 2_400 - scroll.bounds.height), animated: false)
        for hidden in [false, true, false] {
            tabs.setTabBarHidden(hidden, animated: false)
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(50))
                window.layoutIfNeeded()
            }
            let expected = MobileGuideScrollConfiguration.bottomOverlap(of: scroll, usesLineupNavigation: false)
            XCTAssertEqual(try XCTUnwrap(reported), expected, accuracy: 1,
                           "The measurement must follow late native bar visibility changes: hidden \(hidden)")
            if !hidden {
                XCTAssertGreaterThan(expected, 0, "The native bar must overlap the full Guide region in this fixture")
            }
        }
    }
}

/// The TV Guide tab's scrollers, with plain rows.
@MainActor
private final class GuideNavigationTestState: ObservableObject {
    @Published var glass = false
    @Published var selection = 1
}

private struct GuideEndHarness: View {
    @ObservedObject var model: GuideNavigationTestState

    var body: some View {
        TabView(selection: $model.selection) {
            NavigationStack {
                GeometryReader { _ in
                    ZStack(alignment: .top) {
                        VStack(spacing: 0) { guide }
                    }
                }
                .navigationTitle("TV Guide").navigationBarTitleDisplayMode(.inline)
            }
            .mobileNativeTabBar(liquidGlass: model.glass)
            .tabItem { Label("TV Guide", systemImage: "tv") }.tag(1)
            Color.clear.mobileNativeTabBar(liquidGlass: model.glass)
                .tabItem { Label("Settings", systemImage: "gear") }.tag(3)
        }
        .mobileNavigationChrome(selection: $model.selection, liquidGlass: model.glass)
    }

    private var guide: some View {
        MobileGuideViewport { viewport, listHeight in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.gray.frame(height: 40)
                    MobileGuideChannelScroll {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<40, id: \.self) { _ in Color.blue.frame(height: 56) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(height: listHeight)
                }
                .frame(width: viewport.size.width * 3, height: viewport.size.height, alignment: .topLeading)
                .background(MobileGuideScrollConfiguration(horizontal: true))
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaPadding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct GuideFirstRowFrame: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

@MainActor
private final class GuideTopReservationTestState: ObservableObject {
    @Published var firstRowFrame: CGRect?
    @Published var resetToken = UUID()
}

private struct GuideTopReservationHarness: View {
    @ObservedObject var model: GuideTopReservationTestState

    var body: some View {
        NavigationStack {
            MobileGuideChannelScroll(resetToken: model.resetToken, protectsTop: true) {
                LazyVStack(spacing: 9) {
                    Text("First favorite")
                        .frame(maxWidth: .infinity)
                        .frame(height: 68)
                        .background {
                            GeometryReader { row in
                                Color.clear.preference(key: GuideFirstRowFrame.self,
                                    value: row.frame(in: .global))
                            }
                        }
                    ForEach(0..<20, id: \.self) { index in
                        Text("Favorite \(index)").frame(height: 68)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, MobileGuideLayoutMetrics.listFirstRowTopInset)
            }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Favorites") }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onPreferenceChange(GuideFirstRowFrame.self) { model.firstRowFrame = $0 }
    }
}

private extension UIView {
    func firstSubview<Found: UIView>(of type: Found.Type, where matches: (Found) -> Bool = { _ in true }) -> Found? {
        for subview in subviews {
            if let match = subview as? Found, matches(match) { return match }
            if let match = subview.firstSubview(of: type, where: matches) { return match }
        }
        return nil
    }
}

final class PlayerFullscreenLayoutTests: XCTestCase {
    func testFullscreenHeightIsTheSameBeforeAndAfterTheChromeHides() {
        // An 844pt screen: first with a navigation bar, tab bar and home
        // indicator in place, then mid-transition, then with all of them gone.
        // The player must be handed the same height at every step, or it grows
        // in visible stages instead of one motion.
        XCTAssertEqual(MobilePlayerLayout.fullscreenHeight(containerHeight: 652, safeAreaTop: 106, safeAreaBottom: 86), 844)
        XCTAssertEqual(MobilePlayerLayout.fullscreenHeight(containerHeight: 738, safeAreaTop: 59, safeAreaBottom: 47), 844)
        XCTAssertEqual(MobilePlayerLayout.fullscreenHeight(containerHeight: 844, safeAreaTop: 0, safeAreaBottom: 0), 844)
    }
}

/// The summary panel and the transport controls share the bottom half of a
/// landscape screen, and a tester found the summary printed across the
/// skip-back button. These pin the clearance rather than the width: what
/// matters is that the panel stops before the controls start.
final class PlayerSynopsisWidthTests: XCTestCase {
    /// Where the centred cluster begins, in the same space the panel lays out
    /// in. The panel starts at zero, so this is the line it must not cross.
    private func clusterStart(available: CGFloat) -> CGFloat {
        (available - MobilePlayerLayout.transportClusterWidth) / 2
    }

    // Every iPhone landscape width the app runs at, from the smallest screen
    // to the largest, safe-area insets and the player's own padding removed.
    func testTheSummaryStopsBeforeTheControlsOnEveryScreen() {
        for available in stride(from: 520.0, through: 860.0, by: 10.0) {
            let width = MobilePlayerLayout.synopsisWidth(available: available, compactHeight: true)
            XCTAssertLessThan(width, clusterStart(available: available),
                              "A \(available)pt landscape leaves the summary across the controls")
        }
    }

    // The screenshot that prompted this: a 956pt screen, 59pt of safe area on
    // each side, 16pt of padding on each side.
    func testTheCaseFromTheReport() {
        let available = 956.0 - 118 - 32
        let width = MobilePlayerLayout.synopsisWidth(available: available, compactHeight: true)
        XCTAssertEqual(width, 283)
        XCTAssertEqual(clusterStart(available: available) - width, 16,
                       "The gap is the one that was asked for, not whatever is left over")
    }

    // Portrait has the height to keep them apart, so the panel is not punished
    // for a problem it does not have there.
    func testPortraitKeepsTheFullWidth() {
        XCTAssertEqual(MobilePlayerLayout.synopsisWidth(available: 361, compactHeight: false), 420)
        XCTAssertEqual(MobilePlayerLayout.synopsisWidth(available: 806, compactHeight: false), 420)
    }

    // A screen wide enough for both takes the panel's natural width rather
    // than stretching it to fill the clearance.
    func testAWideScreenDoesNotStretchThePanel() {
        XCTAssertEqual(MobilePlayerLayout.synopsisWidth(available: 2000, compactHeight: true), 420)
    }
}
