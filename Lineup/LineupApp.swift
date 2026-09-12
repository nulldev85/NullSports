import SwiftUI
import UIKit

@main
struct LineupApp: App {
    @StateObject private var library = SportsLibrary()
    @StateObject private var media = MediaLibrary()

    init() {
        // Before anything is drawn: a view built ahead of this would ask for a
        // face the process does not have yet and get the system font instead.
        LineupFonts.register()
        retireRemovedThemes()
        #if os(tvOS)
        applyLineupTabBarTheme()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(media)
                // Inter for everything that never asked for a font of its own
                // -- form rows, field text, a progress view's label. Without
                // this they keep the system font and the app reads in two
                // typefaces depending on how carefully each line was written.
                .environment(\.font, .inter(.body))
                .preferredColorScheme(.dark)
        }
    }
}

/// Lineup used to offer five themes and now offers two. A device that still
/// has one of the retired names stored would render in Signal -- the fallback
/// for a name that no longer parses -- while the settings screen showed
/// nothing selected, because the stored string matches no row. Rewriting the
/// name at launch keeps the two in agreement.
private func retireRemovedThemes() {
    let defaults = UserDefaults.standard
    guard let stored = defaults.string(forKey: LineupTheme.storageKey),
          LineupTheme(rawValue: stored) == nil else { return }
    defaults.set(LineupTheme.signal.rawValue, forKey: LineupTheme.storageKey)
}

#if os(tvOS)
func applyLineupTabBarTheme() {
    let accent = UIColor(LineupStyle.lightPurple)
    let bars = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .flatMap { window in allTabBars(in: window) }
    // The tab bar is UIKit, so it keeps the system font unless it is handed
    // another one -- and it is the one piece of chrome on screen, so a guessed
    // point size would be the most visible mistake in the app. The size is
    // read off a label tvOS has already laid out and only the family is
    // changed; with no bar on screen yet, nothing is set and the labels are
    // restyled on the pass that follows the first layout.
    let titleFont = tabBarTitleFont(in: bars)
    let appearance = UITabBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = UIColor(LineupStyle.background)
    appearance.selectionIndicatorTintColor = UIColor(LineupStyle.focused)
    for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
        for state in [item.normal, item.selected, item.disabled, item.focused] {
            state.iconColor = accent
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: accent]
            if let titleFont { attributes[.font] = titleFont }
            state.titleTextAttributes = attributes
        }
    }
    UITabBar.appearance().standardAppearance = appearance
    UITabBar.appearance().scrollEdgeAppearance = appearance
    UITabBar.appearance().unselectedItemTintColor = accent
    // The appearance proxy above only reaches bars built after this point, and
    // the tab bar is the one piece of chrome that outlives a theme switch --
    // it sits above the part of the tree that is rebuilt, so nothing else is
    // going to repaint it. Assigning an appearance to a bar already on screen
    // does not redraw it either; it is picked up at the next layout pass, so
    // one is asked for here rather than waiting for something else to cause
    // it. Without this the bar keeps the old palette until the view is
    // disturbed for an unrelated reason.
    bars.forEach { bar in
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.unselectedItemTintColor = accent
        if let titleFont {
            for label in tabBarLabels(in: bar) {
                label.font = titleFont.withSize(label.font.pointSize)
            }
        }
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
    }
}

private func allTabBars(in view: UIView) -> [UITabBar] {
    (view as? UITabBar).map { [$0] } ?? view.subviews.flatMap { allTabBars(in: $0) }
}

private func tabBarLabels(in view: UIView) -> [UILabel] {
    (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { tabBarLabels(in: $0) }
}

/// Inter at whatever size tvOS is drawing tab titles at, or nothing when there
/// is no bar on screen to measure -- in which case the system font stays, which
/// is the right answer over a wrong size.
private func tabBarTitleFont(in bars: [UITabBar]) -> UIFont? {
    let sizes = bars.flatMap { tabBarLabels(in: $0) }.map(\.font.pointSize)
    guard let size = sizes.max() else { return nil }
    return UIFont(name: LineupFonts.face(for: .semibold), size: size)
}
#endif
