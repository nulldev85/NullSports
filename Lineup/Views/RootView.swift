import SwiftUI
import Foundation

struct RootView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(LineupTheme.storageKey) private var selectedTheme = LineupTheme.signal.rawValue

    var body: some View {
        Group {
            if library.hasProfile || media.hasProfile {
                // MainView holds the selected tab, so the theme scope goes
                // inside it, around each tab's content. Re-identifying from
                // here would take the tab with it and move the viewer off the
                // settings screen they just used.
                MainView()
            } else {
                InitialSourceSetupView().lineupThemeScope(selectedTheme)
            }
        }
        .foregroundStyle(LineupStyle.text)
        .tint(LineupStyle.highlight)
        .background(LineupStyle.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.22), value: selectedTheme)
        #if os(tvOS)
        // Every focusable surface in this app draws its own focus -- a filled
        // background, a lift, a border. tvOS's plate was drawn on top of that,
        // sized to the whole control, so anything that missed a local
        // focusEffectDisabled() carried a second, much larger frame. Disabling
        // it here covers the whole tree, including controls added later, rather
        // than relying on every call site to remember.
        .focusEffectDisabled()
        .onChange(of: selectedTheme) { _, _ in applyLineupTabBarTheme() }
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
    @AppStorage(LineupTheme.storageKey) private var selectedTheme = LineupTheme.signal.rawValue

    var body: some View {
        // Each tab's content is scoped, not the TabView: the bar and the
        // selection survive a switch, and only what is painted is redrawn.
        TabView(selection: $selectedTab) {
            LiveView(isActive: selectedTab == 0)
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Live", systemImage: selectedTab == 0 ? "play.rectangle.fill" : "play.rectangle") }
                .tag(0)
            GuideView(isActive: selectedTab == 1)
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Guide", systemImage: selectedTab == 1 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle") }
                .tag(1)
            MediaServersView()
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Library", systemImage: selectedTab == 2 ? "play.square.stack.fill" : "play.square.stack") }
                .tag(2)
            AccountView(selectedTab: $selectedTab)
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Account", systemImage: selectedTab == 3 ? "person.crop.circle.fill" : "person.crop.circle") }
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
    }
}
#endif
