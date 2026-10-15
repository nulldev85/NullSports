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
    func testNavigationClearanceDoesNotAccumulateAcrossInsetRewrites() {
        let scroll = UIScrollView()
        MobileGuideScrollConfiguration.configure(scroll, horizontal: false)
        let cases: [(CGFloat, CGFloat)] = [(0, 118), (166, 83), (152, 118), (34, 83), (118, 0)]
        for (previous, overlap) in cases {
            scroll.contentInset = UIEdgeInsets(top: 7, left: 11, bottom: previous, right: 13)
            MobileGuideScrollConfiguration.setBottomClearance(scroll, overlap: overlap)
            MobileGuideScrollConfiguration.setBottomClearance(scroll, overlap: overlap)
            XCTAssertEqual(scroll.contentInset, UIEdgeInsets(top: 7, left: 11, bottom: overlap, right: 13))
            XCTAssertEqual(scroll.adjustedContentInset.bottom, overlap)
            XCTAssertEqual(scroll.verticalScrollIndicatorInsets.bottom, overlap)
        }
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
        // Time for SwiftUI and the measured UIKit clearance to settle.
        for glass in [false, true, false] {
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
                // The custom bar reserves its area above the home indicator;
                // the Guide viewport must end before that area begins.
                let boundary = try XCTUnwrap(MobileLineupNavigationBoundary.find(in: window))
                barTop = boundary.convert(boundary.bounds, to: window).minY
                XCTAssertGreaterThan(barTop, 0)
                XCTAssertLessThan(barTop, window.bounds.maxY - window.safeAreaInsets.bottom - 44)
            }
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
        GeometryReader { viewport in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.gray.frame(height: 40)
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<40, id: \.self) { _ in Color.blue.frame(height: 56) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(MobileGuideScrollConfiguration(horizontal: false))
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                    .contentMargins(.bottom, 0, for: .scrollContent)
                    .contentMargins(.bottom, 0, for: .scrollIndicators)
                    .frame(height: max(0, viewport.size.height - 40))
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
