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

/// Keep the existing tag values: Settings links and saved tab state use them.
enum MobileNavigationTab: Int, CaseIterable, Identifiable {
    case sports = 0, guide = 1, library = 2, search = 4, settings = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sports: "Sports"
        case .guide: "TV Guide"
        case .library: "Library"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    func icon(selected: Bool) -> Image {
        switch self {
        case .sports: Image(selected ? "Tab-Live-Selected" : "Tab-Live")
        case .guide: Image(selected ? "Tab-Guide-Selected" : "Tab-Guide")
        case .library: Image(systemName: selected ? "play.square.stack.fill" : "play.square.stack")
        case .search: Image(systemName: "magnifyingglass")
        case .settings: Image(selected ? "Tab-Account-Selected" : "Tab-Account")
        }
    }
}

private struct MobileUsesLineupNavigationKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MobileTabNavigationKey: EnvironmentKey {
    static let defaultValue: MobileTabNavigation? = nil
}

extension EnvironmentValues {
    fileprivate var mobileTabNavigation: MobileTabNavigation? {
        get { self[MobileTabNavigationKey.self] }
        set { self[MobileTabNavigationKey.self] = newValue }
    }
    var mobileUsesLineupNavigation: Bool {
        get { self[MobileUsesLineupNavigationKey.self] }
        set { self[MobileUsesLineupNavigationKey.self] = newValue }
    }
}

/// A solid panel matching the rest of Lineup, with the same five destinations
/// and selection binding as Apple's bar. Buttons select immediately.
struct MobileLineupNavigationBar: View {
    @Binding var selection: Int
    let activate: (MobileNavigationTab) -> Void
    @AppStorage(LineupAccent.storageKey) private var accentHex = LineupAccent.red.hex
    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MobileNavigationTab.allCases) { tab in
                let selected = selection == tab.rawValue
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    activate(tab)
                } label: {
                    VStack(spacing: 5) {
                        tab.icon(selected: selected)
                            .resizable().scaledToFit()
                            .frame(width: 25, height: 24)
                        Text(tab.title)
                            .font(.inter(labelSize, .semibold))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selected ? Color.white : LineupPanelStyle.caption)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .padding(.vertical, 3)
                    .background(selected ? LineupPanelStyle.well : .clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(alignment: .top) {
                        if selected {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(LineupAccent.accent(forHex: accentHex).color)
                                .frame(width: 22, height: 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MobileNavigationButtonStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("lineup.navigation.tab.\(tab.rawValue)")
            }
        }
        .padding(5)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LineupPanelStyle.divider, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6).padding(.bottom, 4)
        .background(LineupStyle.background.ignoresSafeArea(edges: .bottom))
        .background(MobileLineupNavigationBoundary().allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
        .accessibilityIdentifier("lineup.navigation.custom")
    }
}

private struct MobileNavigationButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Use the existing native containers so a tab tap returns home without
/// replacing the tab's controllers, view models, or active playback session.
@MainActor
final class MobileTabNavigation: ObservableObject {
    weak var tabs: UITabBarController?
    private struct Home {
        weak var probe: MobileTabHomeRegistration.Probe?
    }
    private var homes: [Int: Home] = [:]
    private var pendingHomes: Set<Int> = []

    fileprivate func register(_ probe: MobileTabHomeRegistration.Probe, for tab: MobileNavigationTab) {
        homes[tab.rawValue] = Home(probe: probe)
        guard pendingHomes.contains(tab.rawValue) else { return }
        // A lazily loaded tab can register after selection. Reset after its
        // SwiftUI update finishes, without retaining the view's state here.
        DispatchQueue.main.async { [weak self, weak probe] in
            guard let self, let probe, self.homes[tab.rawValue]?.probe === probe,
                  self.pendingHomes.remove(tab.rawValue) != nil else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { probe.reset?() }
        }
    }

    func activate(_ tab: MobileNavigationTab, selection: () -> Void) {
        let index = MobileNavigationTab.allCases.firstIndex(of: tab)!
        let reselection = tabs?.selectedIndex == index
        let home = homes[tab.rawValue]?.probe
        if home == nil { pendingHomes.insert(tab.rawValue) }
        else { pendingHomes.remove(tab.rawValue) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection()
            home?.reset?()
        }
        guard let tabs, let controllers = tabs.viewControllers, controllers.indices.contains(index) else { return }
        // Commit immediately; SwiftUI's binding update reconciles the same
        // selection on its next render, without animating the entire page.
        if tabs.selectedIndex != index { tabs.selectedIndex = index }
        if home == nil {
            Self.returnHome(in: controllers[index], animated: reselection && tabs.viewIfLoaded?.window != nil
                            && !UIAccessibility.isReduceMotionEnabled)
        } else {
            // SwiftUI owns its path. A direct UIKit pop does not clear it.
            DispatchQueue.main.async { [weak self] in
                guard self?.tabs?.selectedIndex == index else { return }
                Self.returnHome(in: controllers[index], animated: false, pop: false)
            }
        }
    }

    private static func returnHome(in controller: UIViewController, animated: Bool, pop: Bool = true) {
        if let navigation = controller as? UINavigationController {
            if pop && navigation.viewControllers.count > 1 {
                navigation.popToRootViewController(animated: animated && navigation.transitionCoordinator == nil)
            }
            if let root = navigation.viewControllers.first?.viewIfLoaded { scrollHome(in: root, animated: animated) }
            return
        }
        if controller.children.isEmpty {
            if let view = controller.viewIfLoaded { scrollHome(in: view, animated: animated) }
        } else {
            for child in controller.children { returnHome(in: child, animated: animated, pop: pop) }
        }
    }

    @discardableResult
    private static func scrollHome(in view: UIView, animated: Bool) -> Bool {
        guard !view.isHidden, view.alpha > 0.01 else { return false }
        if let scroll = view as? UIScrollView, scroll.scrollsToTop,
           scroll.bounds.height > 0, scroll.contentSize.height > scroll.bounds.height + 1 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top),
                                    animated: animated)
            return true
        }
        for child in view.subviews {
            if scrollHome(in: child, animated: animated) { return true }
        }
        return false
    }
}

/// Root-owned SwiftUI resets also handle destination-based NavigationLinks,
/// which are not represented in a bound NavigationPath.
private struct MobileTabHomeRegistration: UIViewRepresentable {
    let tab: MobileNavigationTab
    let reset: () -> Void
    @Environment(\.mobileTabNavigation) private var navigation

    final class Probe: UIView {
        var reset: (() -> Void)?
    }
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }
    func updateUIView(_ probe: Probe, context: Context) {
        probe.reset = reset
        navigation?.register(probe, for: tab)
    }
}

/// A measurable UIKit boundary for nested Guide scrollers. SwiftUI preference
/// values do not reliably cross TabView/NavigationStack hosting boundaries.
struct MobileLineupNavigationBoundary: UIViewRepresentable {
    final class Boundary: UIView {}
    func makeUIView(context: Context) -> Boundary {
        let view = Boundary()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Boundary, context: Context) {}

    static func find(in view: UIView) -> Boundary? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        if let boundary = view as? Boundary, boundary.bounds.height > 0 { return boundary }
        for child in view.subviews {
            if let boundary = find(in: child) { return boundary }
        }
        return nil
    }
}

private struct MobileNavigationChrome: ViewModifier {
    @Binding var selection: Int
    let liquidGlass: Bool
    let fullscreen: Bool
    @StateObject private var navigation = MobileTabNavigation()

    func body(content: Content) -> some View {
        let glass = liquidGlass && MobileNavigationStyle.supportsGlass
        content
            .environment(\.mobileUsesLineupNavigation, !glass)
            .environment(\.mobileTabNavigation, navigation)
            .toolbar(glass && !fullscreen ? .visible : .hidden, for: .tabBar)
            .background(MobileTabBarAppearance(liquidGlass: glass, navigation: navigation)
                .frame(width: 0, height: 0).allowsHitTesting(false))
            // Reserve room for the panel, so bottom rows and buttons remain
            // reachable. Both bars stand aside for full-screen playback.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !glass && !fullscreen {
                    MobileLineupNavigationBar(selection: $selection) { tab in
                        navigation.activate(tab) { selection = tab.rawValue }
                    }
                }
            }
    }
}

extension View {
    func mobileTabHome(_ tab: MobileNavigationTab, reset: @escaping () -> Void) -> some View {
        background(MobileTabHomeRegistration(tab: tab, reset: reset)
            .frame(width: 0, height: 0).allowsHitTesting(false))
    }
    /// State the visibility on each destination too: its NavigationStack owns
    /// the toolbar preference, including after a push or return from a player.
    func mobileNativeTabBar(liquidGlass: Bool, fullscreen: Bool = false) -> some View {
        toolbar(liquidGlass && MobileNavigationStyle.supportsGlass && !fullscreen ? .visible : .hidden,
                for: .tabBar)
    }

    func mobileNavigationChrome(selection: Binding<Int>, liquidGlass: Bool,
                                fullscreen: Bool = false) -> some View {
        modifier(MobileNavigationChrome(selection: selection, liquidGlass: liquidGlass, fullscreen: fullscreen))
    }
}

/// Changes the existing native bar's background without replacing TabView,
/// adding gestures, or changing its selection, controllers or hit targets.
struct MobileTabBarAppearance: UIViewRepresentable {
    let liquidGlass: Bool
    var navigation: MobileTabNavigation? = nil

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.liquidGlass = liquidGlass
        probe.navigation = navigation
        probe.refresh()
    }

    final class Probe: UIView {
        var liquidGlass = false
        weak var navigation: MobileTabNavigation?
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
            if bar == nil || navigation?.tabs == nil {
                let tabs = Self.findTabController(in: window.rootViewController)
                navigation?.tabs = tabs
                bar = tabs?.tabBar
            }
            guard let bar else { return }
            style.apply(to: bar, liquidGlass: liquidGlass)
        }

        private static func findTabController(in controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let tabs = findTabController(in: child) { return tabs }
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
