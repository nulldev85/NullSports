import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

@MainActor
final class NavigationOrderTests: XCTestCase {
    func testSavedOrderKeepsStableTagsAndRepairsMissingDuplicateOrUnknownEntries() throws {
        XCTAssertEqual(MobileNavigationOrder.tabs(in: "3,4,2,1,0").map(\.rawValue), [3, 4, 2, 1, 0])
        XCTAssertEqual(MobileNavigationOrder.tabs(in: "4,4,99,bad,3").map(\.rawValue), [4, 3, 0, 1, 2])
        XCTAssertEqual(MobileNavigationOrder.tabs(in: ""), MobileNavigationTab.allCases)
        let suite = "NavigationOrderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MobileNavigationOrder.encode([.settings, .guide, .sports, .search, .library]),
                     forKey: MobileNavigationOrder.storageKey)
        XCTAssertEqual(MobileNavigationOrder.tabs(in: defaults.string(forKey: MobileNavigationOrder.storageKey) ?? ""),
                       [.settings, .guide, .sports, .search, .library])
    }

    func testCustomTabActivationUsesTheReorderedControllerAndReturnsItHome() {
        let navigation = MobileTabNavigation()
        navigation.order = [.settings, .search, .library, .guide, .sports]
        let roots = navigation.order.map { _ in UIViewController() }
        let stacks = roots.map { UINavigationController(rootViewController: $0) }
        let tabs = UITabBarController()
        tabs.setViewControllers(stacks, animated: false)
        navigation.tabs = tabs
        for (index, destination) in navigation.order.enumerated() {
            stacks[index].pushViewController(UIViewController(), animated: false)
            var selection = -1
            navigation.activate(destination) { selection = destination.rawValue }
            XCTAssertEqual(selection, destination.rawValue)
            XCTAssertEqual(tabs.selectedIndex, index)
            XCTAssertEqual(stacks[index].viewControllers.count, 1)
            XCTAssertTrue(stacks[index].viewControllers.first === roots[index])
        }
    }
}
