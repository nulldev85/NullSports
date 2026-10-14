import SwiftUI
import UIKit

enum MobileNavigationStyle {
    /// Device-local: this choice changes only the iPhone's bottom tab bar.
    static let glassKey = "lineup.appearance.navigationGlass"

    static var supportsGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

/// Changes the existing native bar's background without replacing TabView,
/// adding gestures, or changing its selection, controllers or hit targets.
struct MobileTabBarAppearance: UIViewRepresentable {
    let liquidGlass: Bool

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.liquidGlass = liquidGlass
        probe.refresh()
    }

    final class Probe: UIView {
        var liquidGlass = false
        private weak var bar: UITabBar?
        private let style = MobileTabBarStyle()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refresh()
            // SwiftUI can attach this background before installing TabView's
            // controller. Try once after that initial layout has completed.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Only discover the controller once. Layout and tab switches do
            // not walk the view hierarchy or recreate the glass material.
            if bar == nil { refresh() }
        }

        func refresh() {
            guard let window else { return }
            if bar == nil { bar = Self.findTabBar(in: window.rootViewController) }
            guard let bar else { return }
            style.apply(to: bar, liquidGlass: liquidGlass)
        }

        private static func findTabBar(in controller: UIViewController?) -> UITabBar? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs.tabBar }
            for child in controller.children {
                if let bar = findTabBar(in: child) { return bar }
            }
            return nil
        }
    }
}

@MainActor
final class MobileTabBarStyle {
    private weak var bar: UITabBar?
    private var appliedGlass: Bool?
    private var nativeAppearance: UITabBarAppearance?
    private var nativeScrollEdgeAppearance: UITabBarAppearance?

    func apply(to bar: UITabBar, liquidGlass: Bool) {
        let enabled = liquidGlass && MobileNavigationStyle.supportsGlass
        guard self.bar !== bar || appliedGlass != enabled else { return }
        if self.bar !== bar {
            // Preserve UIKit's untouched appearance before applying the solid
            // option. Restore it for On so Apple owns all glass and selection
            // rendering, including the floating geometry and native animation.
            nativeAppearance = bar.standardAppearance.copy() as? UITabBarAppearance
            nativeScrollEdgeAppearance = bar.scrollEdgeAppearance?.copy() as? UITabBarAppearance
        }
        self.bar = bar
        appliedGlass = enabled

        if enabled {
            bar.standardAppearance = nativeAppearance ?? UITabBarAppearance()
            bar.scrollEdgeAppearance = nativeScrollEdgeAppearance
        } else {
            let appearance = nativeAppearance?.copy() as? UITabBarAppearance ?? UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(LineupStyle.background)
            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
        }
        bar.setNeedsLayout()
    }
}
