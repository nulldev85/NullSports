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
        .alert("Couldn’t Connect", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "Unknown error").foregroundColor(LineupStyle.lightPurple)
        }
    }
}

#if os(tvOS)
struct MainView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveView(isActive: selectedTab == 0)
                .tabItem { Label("Sports", systemImage: selectedTab == 0 ? "play.rectangle.fill" : "play.rectangle") }
                .tag(0)
            GuideView(isActive: selectedTab == 1)
                .tabItem { Label("TV Guide", systemImage: selectedTab == 1 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle") }
                .tag(1)
            MediaServersView()
                .tabItem { Label("Library", systemImage: selectedTab == 2 ? "play.square.stack.fill" : "play.square.stack") }
                .tag(2)
            // Everything at once -- the Library, live TV, the guide and VOD --
            // each result saying which of the other tabs it lives in.
            AppSearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(4)
            AccountView(selectedTab: $selectedTab)
                .tabItem { Label("Settings", systemImage: selectedTab == 3 ? "person.crop.circle.fill" : "person.crop.circle") }
                .tag(3)
        }
        // The four tabs are Lineup's primary navigation, not transient
        // playback chrome. Leaving visibility on automatic lets tvOS hide the
        // bar during a Library push or full-screen player and occasionally
        // fail to restore it afterward. Keep the route back to every section
        // present; focus can still move down into content normally.
        .toolbar(.visible, for: .tabBar)
        .ignoresSafeArea(.container, edges: .bottom)
        .tint(.white)
        // Beside the tab bar, where the set's own notices appear, over every
        // tab. A player covers it: they are all full-screen presentations.
        .overlay(alignment: .topTrailing) { DataRefreshPopup() }
    }
}
#endif
