import SwiftUI
import UIKit

@main
struct LineupApp: App {
    @State private var library = SportsLibrary()
    @State private var media = MediaLibrary()
    @StateObject private var cloud = CloudSettingsSync.shared
    @StateObject private var reminders = GameReminders.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything is drawn: a view built ahead of this would ask for a
        // face the process does not have yet and get the system font instead.
        LineupFonts.register()
        forgetThemeChoice()
        // Subtitle files a run that ended mid-title left behind.
        let launched = Date()
        Task.detached(priority: .utility) { OnlineSubtitleFiles.removeLeftovers(before: launched) }
        #if os(tvOS)
        applyLineupTabBarTheme()
        PlaybackJournal.shared.note("Lineup opened")
        #else
        // Apple's daily report on how the app ran, for Diagnostics.
        MobileDeviceReports.shared.start()
        // Navigation titles are drawn by UIKit: set in the app's rounded face.
        UINavigationBar.appearance().titleTextAttributes = [.font: roundedUIFont(17, .heavy)]
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: roundedUIFont(34, .heavy)]
        // The rest of the text UIKit draws itself: the tab bar's names, the
        // search field, segmented pickers and the toolbar's buttons.
        UITabBarItem.appearance().setTitleTextAttributes([.font: roundedUIFont(10, .semibold)], for: .normal)
        UISearchTextField.appearance().font = roundedUIFont(17, .regular)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: roundedUIFont(13, .semibold)], for: .normal)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: roundedUIFont(17, .semibold)], for: .normal)
        // The optional glass belongs to the bottom tab bar. Page headers keep
        // the app's solid background when linked against the current SDK.
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = UIColor(LineupStyle.background)
        navigationAppearance.titleTextAttributes = [.font: roundedUIFont(17, .heavy), .foregroundColor: UIColor.white]
        navigationAppearance.largeTitleTextAttributes = [.font: roundedUIFont(34, .heavy), .foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(media)
                .environmentObject(reminders)
                .environmentObject(cloud)
                .environmentObject(library.refreshProgress)
                // Inter for everything that never asked for a font of its own
                // -- form rows, field text, a progress view's label. Without
                // this they keep the system font and the app reads in two
                // typefaces depending on how carefully each line was written.
                .environment(\.font, .inter(.body))
                // And the rounded cut for any font that names no design of
                // its own -- a symbol's size, a text style set by hand -- so
                // the whole app, sheets included, reads in the one face.
                .fontDesign(.rounded)
                .preferredColorScheme(.dark)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await cloud.sync()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(90)) } catch { return }
                        await cloud.sync()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: CloudSettingsSync.imported)) { _ in
                    Task {
                        await library.restoreCloudSettings()
                        await media.restoreCloudSettings()
                        reminders.restore()
                    }
                }
                .onChange(of: library.gamesRevision, initial: true) {
                    reminders.updateGames(library.gamesByLeague.values.flatMap { $0 })
                }
                .task { await media.prepareProviderVOD() }
                #if os(tvOS)
                // "It stopped and went back to the menu" is often the screen
                // saver, Home or the television sleeping rather than the
                // player, so the playback log says when the app left the
                // front and came back.
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: PlaybackJournal.shared.note("App back in front")
                    case .inactive: PlaybackJournal.shared.note("App covered: the screen saver, or the TV's own menus")
                    case .background: PlaybackJournal.shared.note("App sent to the background: Home, or the TV went to sleep")
                    @unknown default: break
                    }
                }
                #endif
        }
    }
}

/// Lineup has one look now, and no theme to choose. The choice a device
/// made when there were several is forgotten rather than left behind.
private func forgetThemeChoice() {
    UserDefaults.standard.removeObject(forKey: "lineup.appearance.theme")
}

#if os(tvOS)
func applyLineupTabBarTheme() {
    // Navigation is app chrome, not part of a content theme. Keeping it white
    // prevents an old palette from lingering in the long-lived tab bar and
    // lets the filled symbol carry selection without another accent competing.
    let selectedColor = UIColor.white
    let normalColor = UIColor.white.withAlphaComponent(0.62)
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
    appearance.selectionIndicatorTintColor = UIColor.white.withAlphaComponent(0.12)
    for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
        for (state, color) in [(item.normal, normalColor), (item.disabled, normalColor.withAlphaComponent(0.45)),
                               (item.selected, selectedColor), (item.focused, selectedColor)] {
            state.iconColor = color
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let titleFont { attributes[.font] = titleFont }
            state.titleTextAttributes = attributes
        }
    }
    UITabBar.appearance().standardAppearance = appearance
    UITabBar.appearance().scrollEdgeAppearance = appearance
    UITabBar.appearance().unselectedItemTintColor = normalColor
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
        bar.unselectedItemTintColor = normalColor
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

/// The app's rounded face at whatever size tvOS is drawing tab titles at, or nothing when there
/// is no bar on screen to measure -- in which case the system font stays, which
/// is the right answer over a wrong size.
private func tabBarTitleFont(in bars: [UITabBar]) -> UIFont? {
    let sizes = bars.flatMap { tabBarLabels(in: $0) }.map(\.font.pointSize)
    guard let size = sizes.max() else { return nil }
    let base = UIFont.systemFont(ofSize: size, weight: .semibold)
    return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
}
#endif

/// The system's rounded face, for the places UIKit draws text itself.
func roundedUIFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
}
