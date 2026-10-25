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

private struct MobileNavigationCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var mobileNavigationIsCompact: Bool {
        get { self[MobileNavigationCompactKey.self] }
        set { self[MobileNavigationCompactKey.self] = newValue }
    }
    fileprivate var mobileTabNavigation: MobileTabNavigation? {
        get { self[MobileTabNavigationKey.self] }
        set { self[MobileTabNavigationKey.self] = newValue }
    }
    var mobileUsesLineupNavigation: Bool {
        get { self[MobileUsesLineupNavigationKey.self] }
        set { self[MobileUsesLineupNavigationKey.self] = newValue }
    }
}

enum MobileLineupNavigationLayout {
    static let sideMargin: CGFloat = 20
    static let padding: CGFloat = 4
    static let itemHeight: CGFloat = 54

    static func bottomGap(safeAreaBottom: CGFloat) -> CGFloat {
        // Match the reference's floating placement on home-indicator phones,
        // with a smaller edge margin when there is no home indicator.
        safeAreaBottom > 0 ? 20 : 8
    }
}

/// A floating capsule around the icons and labels. It shares the
/// native bar's destinations and selection; button actions remain immediate.
struct MobileLineupNavigationBar: View {
    @Binding var selection: Int
    var navigation: MobileTabNavigation? = nil
    var compact = false
    var liquidGlass = false
    let activate: (MobileNavigationTab) -> Void
    @AppStorage(MobileNavigationOrder.storageKey) private var savedOrder = MobileNavigationOrder.defaultValue
    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 0) {
            ForEach(compact ? [.sports] : MobileNavigationOrder.tabs(in: savedOrder)) { tab in
                let selected = selection == tab.rawValue
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    activate(tab)
                } label: {
                    VStack(spacing: 3) {
                        tab.icon(selected: compact || selected)
                            .renderingMode(.template).resizable().scaledToFit()
                            .frame(width: compact ? 28 : 25, height: compact ? 28 : 24)
                            .foregroundStyle(!liquidGlass && (compact || selected) ? LineupStyle.highlight : (selected ? Color.white : LineupPresentationStyle.secondary))
                        if !compact {
                            Text(tab.title)
                                .font(.inter(labelSize, .semibold))
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }
                    .foregroundStyle(compact || selected ? LineupPresentationStyle.text : LineupPresentationStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: MobileLineupNavigationLayout.itemHeight)
                    .background {
                        if selected && !compact {
                            Capsule().fill(liquidGlass ? LineupPanelStyle.well : LineupStyle.highlight.opacity(0.11))
                                .overlay(Capsule().strokeBorder(liquidGlass ? .clear : LineupStyle.highlight.opacity(0.18), lineWidth: 0.6))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(MobileNavigationButtonStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("lineup.navigation.tab.\(tab.rawValue)")
            }
        }
        .frame(width: compact ? MobileLineupNavigationLayout.itemHeight : nil)
        .padding(MobileLineupNavigationLayout.padding)
        .modifier(MobileNavigationSurface(liquidGlass: liquidGlass))
        .background(MobileLineupNavigationBoundary(navigation: navigation).allowsHitTesting(false))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MobileLineupNavigationLayout.sideMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
        .accessibilityIdentifier("lineup.navigation.custom")
        .accessibilityAction(named: "Show all tabs") { navigation?.expand() }
    }
}

private struct MobileNavigationSurface: ViewModifier {
    let liquidGlass: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), liquidGlass {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(LineupPresentationStyle.card, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.16), LineupPresentationStyle.divider, .white.opacity(0.035)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8).allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
        }
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
    @Published private(set) var windowBottomInset: CGFloat = 0
    @Published private(set) var isCompact = false
    var order = MobileNavigationTab.allCases
    fileprivate weak var bottomBoundary: UIView?
    fileprivate var showsCustomNavigation = false
    fileprivate var currentSelection = 0
    private let contentInsets = MobileNavigationContentInsets()
    private var insetsUpdateScheduled = false
    private var windowMetricsUpdateScheduled = false
    private var scrollUpdateScheduled = false
    private var scrollInteractionEnabled = true
    let scrollObservation = MobileNavigationScrollObserver()
    private struct Home {
        weak var probe: MobileTabHomeRegistration.Probe?
    }
    private var homes: [Int: Home] = [:]
    private var pendingHomes: Set<Int> = []

    init() {
        scrollObservation.onChange = { [weak self] compact in self?.isCompact = compact }
    }

    func expand() { scrollObservation.expand() }

    fileprivate func requestScrollObservationUpdate(enabled: Bool) {
        scrollInteractionEnabled = enabled
        guard !scrollUpdateScheduled else { return }
        scrollUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollUpdateScheduled = false
            self.scrollObservation.update(tabs: self.tabs, selection: self.currentSelection,
                                          enabled: self.scrollInteractionEnabled)
        }
    }

    fileprivate func detachScrollObservation() { scrollObservation.detach() }

    fileprivate func requestWindowMetrics(from view: UIView) {
        guard let window = view.window, !windowMetricsUpdateScheduled else { return }
        windowMetricsUpdateScheduled = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.windowMetricsUpdateScheduled = false
            guard let window else { return }
            let bottom = window.safeAreaInsets.bottom
            if abs(self.windowBottomInset - bottom) > 0.5 { self.windowBottomInset = bottom }
        }
    }

    fileprivate func requestContentInsetsUpdate() {
        guard !insetsUpdateScheduled else { return }
        insetsUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.insetsUpdateScheduled = false
            guard self.showsCustomNavigation else { self.contentInsets.restore(); return }
            // The Guide already owns its measured scroller margins.
            guard self.currentSelection != MobileNavigationTab.guide.rawValue,
                  let tabs = self.tabs,
                  let index = self.order.firstIndex(where: { $0.rawValue == self.currentSelection }),
                  tabs.selectedIndex == index,
                  let controller = tabs.selectedViewController,
                  let boundary = self.bottomBoundary, boundary.window != nil else { return }
            self.contentInsets.apply(to: controller, above: boundary) { [weak self] in
                self?.requestContentInsetsUpdate()
            }
        }
    }

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
        guard let index = order.firstIndex(of: tab) else { return }
        expand()
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
        currentSelection = tab.rawValue
        requestContentInsetsUpdate()
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
    /// Sent by the boundary's window when its physical coverage changes.
    /// A nested scroll viewport can stay the same size while this bar moves.
    static let geometryDidChange = Notification.Name("Lineup.navigationBoundaryGeometryDidChange")
    var navigation: MobileTabNavigation? = nil
    final class Boundary: UIView {
        weak var navigation: MobileTabNavigation?
        private weak var reportedWindow: UIWindow?
        private var reportedFrame: CGRect?
        private var geometryReportScheduled = false

        func requestGeometryReport() {
            guard !geometryReportScheduled else { return }
            geometryReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.geometryReportScheduled = false
                self.reportGeometry()
            }
        }

        private func reportWindowChange() {
            if reportedWindow !== window {
                let previous = reportedWindow
                reportedWindow = window
                reportedFrame = nil
                if let previous {
                    NotificationCenter.default.post(name: MobileLineupNavigationBoundary.geometryDidChange, object: previous)
                }
            }
        }

        private func reportGeometry() {
            reportWindowChange()
            guard let window, bounds.height > 0 else { return }
            let frame = convert(bounds, to: window)
            guard reportedFrame != frame else { return }
            reportedFrame = frame
            NotificationCenter.default.post(name: MobileLineupNavigationBoundary.geometryDidChange, object: window)
        }

        private func report() {
            if window != nil { navigation?.bottomBoundary = self }
            navigation?.requestContentInsetsUpdate()
            requestGeometryReport()
        }
        // Origin-only placement changes do not require layoutSubviews. This
        // includes the home-indicator adjustment after native glass is hidden.
        override var frame: CGRect { didSet { if frame != oldValue { requestGeometryReport() } } }
        override var bounds: CGRect { didSet { if bounds != oldValue { requestGeometryReport() } } }
        override var center: CGPoint { didSet { if center != oldValue { requestGeometryReport() } } }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Notify removal while this view is still alive. A queued weak
            // callback alone can disappear when SwiftUI dismantles the bar.
            reportWindowChange()
            report()
        }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }
    }
    func makeUIView(context: Context) -> Boundary {
        let view = Boundary()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Boundary, context: Context) {
        view.navigation = navigation
        if view.window != nil { navigation?.bottomBoundary = view }
        navigation?.requestContentInsetsUpdate()
        view.requestGeometryReport()
    }

    static func dismantleUIView(_ view: Boundary, coordinator: ()) {
        if view.navigation?.bottomBoundary === view { view.navigation?.bottomBoundary = nil }
        view.navigation?.requestContentInsetsUpdate()
        view.navigation = nil
    }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MobileNavigationOrder.storageKey) private var savedOrder = MobileNavigationOrder.defaultValue

    func body(content: Content) -> some View {
        let glass = liquidGlass && MobileNavigationStyle.supportsGlass
        content
            .environment(\.mobileUsesLineupNavigation, !glass || navigation.isCompact)
            .environment(\.mobileTabNavigation, navigation)
            .environment(\.mobileNavigationIsCompact, navigation.isCompact)
            .toolbar(glass && !fullscreen && !navigation.isCompact ? .visible : .hidden, for: .tabBar)
            .background(MobileTabBarAppearance(liquidGlass: glass, navigation: navigation,
                                              order: MobileNavigationOrder.tabs(in: savedOrder),
                                              selection: selection, fullscreen: fullscreen,
                                              active: scenePhase == .active, compact: navigation.isCompact)
                .frame(width: 0, height: 0).allowsHitTesting(false))
            // UIKit's navigation container owns the measured reservation.
            // A second outer SwiftUI inset would count the same panel twice.
            // Extend only the floating overlay into the bottom container area.
            // Page clearance still comes from the actual capsule boundary.
            .overlay(alignment: .bottom) {
                if (!glass || navigation.isCompact) && !fullscreen {
                    MobileLineupNavigationBar(selection: $selection, navigation: navigation,
                                              compact: navigation.isCompact, liquidGlass: glass) { tab in
                        navigation.activate(tab) { selection = tab.rawValue }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: navigation.isCompact)
                    .padding(.bottom, MobileLineupNavigationLayout.bottomGap(safeAreaBottom: navigation.windowBottomInset))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
    }
}

private struct MobileNativeTabBarVisibility: ViewModifier {
    let liquidGlass: Bool
    let fullscreen: Bool
    @Environment(\.mobileNavigationIsCompact) private var compact
    func body(content: Content) -> some View {
        content.toolbar(liquidGlass && MobileNavigationStyle.supportsGlass && !fullscreen && !compact
                        ? .visible : .hidden, for: .tabBar)
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
        modifier(MobileNativeTabBarVisibility(liquidGlass: liquidGlass, fullscreen: fullscreen))
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
    var order = MobileNavigationTab.allCases
    var selection = 0
    var fullscreen = false
    var active = true
    // Keep this a value input: changing a property on the same navigation
    // object does not invalidate a UIViewRepresentable's unchanged inputs.
    var compact = false

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.liquidGlass = liquidGlass
        probe.nativeBarShouldBeHidden = !liquidGlass || fullscreen || compact
        probe.scrollInteractionEnabled = active && !fullscreen
        probe.navigation = navigation
        navigation?.order = order
        navigation?.currentSelection = selection
        navigation?.showsCustomNavigation = (!liquidGlass || compact) && !fullscreen
        probe.refresh()
    }

    static func dismantleUIView(_ probe: Probe, coordinator: ()) {
        probe.navigation?.detachScrollObservation()
    }

    final class Probe: UIView {
        var liquidGlass = false
        var nativeBarShouldBeHidden = true
        var scrollInteractionEnabled = true
        weak var navigation: MobileTabNavigation?
        private weak var bar: UITabBar?
        private let style = MobileTabBarStyle()
        private var visibilityUpdateScheduled = false

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
            requestNativeVisibilityUpdate()
            navigation?.requestWindowMetrics(from: self)
            navigation?.requestContentInsetsUpdate()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            requestNativeVisibilityUpdate()
            navigation?.requestWindowMetrics(from: self)
            navigation?.requestContentInsetsUpdate()
        }

        func refresh() {
            guard let window else { return }
            navigation?.requestWindowMetrics(from: self)
            if bar == nil || navigation?.tabs == nil {
                let tabs = Self.findTabController(in: window.rootViewController)
                navigation?.tabs = tabs
                bar = tabs?.tabBar
            }
            // UIKit can replace its floating tab bar during a visibility
            // transition. Keep styling and visibility on the live instance.
            if let current = navigation?.tabs?.tabBar { bar = current }
            guard let bar else { return }
            style.apply(to: bar, liquidGlass: liquidGlass)
            requestNativeVisibilityUpdate()
            navigation?.requestScrollObservationUpdate(enabled: scrollInteractionEnabled)
            navigation?.requestContentInsetsUpdate()
        }

        private func requestNativeVisibilityUpdate() {
            guard !visibilityUpdateScheduled else { return }
            visibilityUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.visibilityUpdateScheduled = false
                guard self.window != nil, let tabs = self.navigation?.tabs else { return }
                // Reconcile after SwiftUI's toolbar/layout pass. In particular,
                // a glass appearance change following the compact animation
                // must not leave the expanded native bar hidden.
                if #available(iOS 26.0, *),
                   tabs.isTabBarHidden != self.nativeBarShouldBeHidden {
                    tabs.setTabBarHidden(self.nativeBarShouldBeHidden, animated: false)
                }
                self.navigation?.requestContentInsetsUpdate()
            }
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
