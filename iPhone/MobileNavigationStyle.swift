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
    private(set) var glassSurface: UIView?

    func apply(to bar: UITabBar, liquidGlass: Bool) {
        let enabled = liquidGlass && MobileNavigationStyle.supportsGlass
        guard self.bar !== bar || appliedGlass != enabled else { return }
        glassSurface?.removeFromSuperview()
        glassSurface = nil
        self.bar = bar
        appliedGlass = enabled

        let appearance = bar.standardAppearance.copy() as? UITabBarAppearance ?? UITabBarAppearance()
        if enabled, #available(iOS 26.0, *) {
            appearance.configureWithTransparentBackground()
            let surface = MobileTabGlassBackground()
            surface.frame = bar.bounds
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Decoration never receives a touch. Native tab buttons keep
            // their original target and immediate selection behavior.
            surface.isUserInteractionEnabled = false
            surface.accessibilityElementsHidden = true
            bar.insertSubview(surface, at: 0)
            glassSurface = surface
        } else {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(LineupStyle.background)
        }
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.setNeedsLayout()
    }
}

@available(iOS 26.0, *)
private final class MobileTabGlassBackground: UIView {
    private let glass: UIVisualEffectView

    override init(frame: CGRect) {
        let effect = UIGlassEffect(style: .regular)
        glass = UIVisualEffectView(effect: effect)
        super.init(frame: frame)
        glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = max(44, bounds.height - safeAreaInsets.bottom)
        glass.frame = CGRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: height)
        glass.layer.cornerRadius = height / 2
    }
}
