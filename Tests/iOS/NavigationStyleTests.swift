import XCTest
import UIKit
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
        XCTAssertNil(style.glassSurface)
        XCTAssertEqual(bar.standardAppearance.backgroundColor, UIColor(LineupStyle.background))
    }

    @MainActor
    func testGlassDecorationCannotInterceptTapsAndIsReusedAcrossUpdates() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Liquid Glass requires iOS 26") }
        let bar = UITabBar(frame: CGRect(x: 0, y: 0, width: 390, height: 83))
        let style = MobileTabBarStyle()
        style.apply(to: bar, liquidGlass: true)
        let surface = try XCTUnwrap(style.glassSurface)
        XCTAssertFalse(surface.isUserInteractionEnabled)
        XCTAssertTrue(surface.accessibilityElementsHidden)
        XCTAssertNil(surface.hitTest(CGPoint(x: 195, y: 24), with: nil))

        style.apply(to: bar, liquidGlass: true)
        XCTAssertTrue(style.glassSurface === surface, "Ordinary tab renders must reuse the glass surface")
    }

    @MainActor
    func testBothStylesKeepTheSameNativeTapTargets() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Liquid Glass requires iOS 26") }
        let bar = UITabBar(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        bar.items = (0..<5).map { UITabBarItem(title: "Tab \($0)", image: UIImage(systemName: "tv"), tag: $0) }
        let style = MobileTabBarStyle()
        style.apply(to: bar, liquidGlass: false)
        bar.layoutIfNeeded()
        let points = (0..<5).map { CGPoint(x: (CGFloat($0) + 0.5) * 78, y: 24) }
        let targets = points.map { bar.hitTest($0, with: nil) }
        XCTAssertTrue(targets.allSatisfy { $0 != nil && $0 !== bar })

        for glass in [true, false] {
            style.apply(to: bar, liquidGlass: glass)
            bar.layoutIfNeeded()
            for (point, original) in zip(points, targets) {
                XCTAssertTrue(bar.hitTest(point, with: nil) === original,
                              "Changing the material must not replace a tab's tap target")
            }
        }
    }
}
