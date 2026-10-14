import SwiftUI
import Foundation

struct RootView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    /// Watched so the app's tint follows the accent; the tabs below redraw
    /// themselves for it.
    @AppStorage(LineupAccent.storageKey) private var accent = LineupAccent.red.hex

    var body: some View {
        Group {
            if library.hasProfile || media.hasProfile {
                MainView()
            } else {
                InitialSourceSetupView().lineupAccentScope(accent)
            }
        }
        .foregroundStyle(LineupStyle.text)
        .tint(LineupStyle.highlight)
        .background(LineupStyle.background.ignoresSafeArea())
        #if os(tvOS)
        // Every focusable surface in this app draws its own focus -- a filled
        // background, a lift, a border. tvOS's plate was drawn on top of that,
        // sized to the whole control, so anything that missed a local
        // focusEffectDisabled() carried a second, much larger frame. Disabling
        // it here covers the whole tree, including controls added later, rather
        // than relying on every call site to remember.
        .focusEffectDisabled()
        // Again once there is a window: the pass in the app's initialiser runs
        // before any tab bar exists, and the bar's own font is read off a label
        // it has laid out.
        .onAppear { applyLineupTabBarTheme() }
        #endif
        .task {
            guard library.hasProfile else { return }
            if library.streams.isEmpty { await library.bootstrap() }
            else { library.refreshSchedule() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && library.hasProfile && !library.streams.isEmpty {
                library.refreshSchedule()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            if library.hasProfile { library.refreshSchedule() }
        }
        // Every refresh of the scores is looked at for the viewer's teams:
        // a game starting, close at the end, or going to overtime is held
        // for a player to show over the picture.
        .onReceive(library.$gamesByLeague) { games in
            GameAlertCenter.shared.observe(games.values.flatMap { $0 }, isFollowing: library.isFollowing)
        }
        #if os(tvOS)
        .tvChoices("Couldn’t Connect", symbol: "exclamationmark.triangle",
                   isPresented: Binding(get: { library.errorMessage != nil },
                                        set: { if !$0 { library.errorMessage = nil } }),
                   message: library.errorMessage ?? "Unknown error", cancelTitle: "OK") { [] }
        #else
        .lineupChoices("Couldn’t Connect", symbol: "exclamationmark.triangle",
                       isPresented: Binding(get: { library.errorMessage != nil },
                                            set: { if !$0 { library.errorMessage = nil } }),
                       message: library.errorMessage ?? "Unknown error", cancelTitle: "OK") { [] }
        #endif
    }
}

#if os(tvOS)
/// Whether the tab bar is up, decided here rather than left to each page.
///
/// A title's page hides the bar for its full-screen artwork. Asked for by
/// the page itself, tvOS was left to put the bar back when the page went,
/// and now and then it did not: the bar stayed gone on every tab until the
/// app was relaunched. Counting the pages open and stating the answer on
/// every tab means a page closing is a change of state the bar follows,
/// and the Library's own screen puts it back whenever it shows.
@MainActor
final class TVTabBarState: ObservableObject {
    @Published private(set) var hidden = false
    private var pagesOpen = 0

    func pageAppeared() { pagesOpen += 1; sync() }
    func pageDisappeared() { pagesOpen = max(0, pagesOpen - 1); sync() }
    /// A tab's own screen is showing: no page is over it.
    func reset() { pagesOpen = 0; sync() }

    private func sync() {
        let hide = pagesOpen > 0
        if hidden != hide { hidden = hide }
    }
}

private struct TVTabBarStateKey: EnvironmentKey {
    static let defaultValue: TVTabBarState? = nil
}

extension EnvironmentValues {
    var tvTabBar: TVTabBarState? {
        get { self[TVTabBarStateKey.self] }
        set { self[TVTabBarStateKey.self] = newValue }
    }
}

private extension View {
    func tabBar(hidden: Bool) -> some View {
        toolbar(hidden ? .hidden : .visible, for: .tabBar)
    }
}

struct MainView: View {
    @State private var selectedTab = 0
    @StateObject private var tabBar = TVTabBarState()
    /// The accent chosen on the phone, which iCloud brings here: the tabs
    /// are drawn again in it when it changes, as the phone's are.
    @AppStorage(LineupAccent.storageKey) private var accent = LineupAccent.red.hex

    var body: some View {
        // The tabs are Lineup's primary navigation, not transient playback
        // chrome. Leaving visibility on automatic lets tvOS hide the bar
        // during a Library push or full-screen player and occasionally fail
        // to restore it afterward, so every tab states it, and only a title's
        // page takes it away (`TVTabBarState`).
        TabView(selection: $selectedTab) {
            LiveView(isActive: selectedTab == 0)
                .lineupAccentScope(accent)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("Sports", systemImage: selectedTab == 0 ? "play.rectangle.fill" : "play.rectangle") }
                .tag(0)
            GuideView(isActive: selectedTab == 1)
                .lineupAccentScope(accent)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("TV Guide", systemImage: selectedTab == 1 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle") }
                .tag(1)
            MediaServersView()
                .lineupAccentScope(accent)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("Library", systemImage: selectedTab == 2 ? "play.square.stack.fill" : "play.square.stack") }
                .tag(2)
            // Everything at once -- the Library, live TV, the guide and VOD --
            // each result saying which of the other tabs it lives in.
            AppSearchView()
                .lineupAccentScope(accent)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(4)
            // Not rebuilt for a new accent: the accent is chosen here, and
            // rebuilding would throw the remote off the swatch it is on.
            AccountView(selectedTab: $selectedTab)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("Settings", systemImage: selectedTab == 3 ? "person.crop.circle.fill" : "person.crop.circle") }
                .tag(3)
        }
        .environment(\.tvTabBar, tabBar)
        // A tab changed is a tab's own screen showing.
        .onChange(of: selectedTab) { _, _ in tabBar.reset() }
        .ignoresSafeArea(.container, edges: .bottom)
        .tint(.white)
        // Beside the tab bar, where the set's own notices appear, over every
        // tab. A player covers it: they are all full-screen presentations.
        .overlay(alignment: .topTrailing) { DataRefreshPopup() }
    }
}
#endif
