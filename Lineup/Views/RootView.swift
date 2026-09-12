import SwiftUI
import Foundation

struct RootView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(LineupTheme.storageKey) private var selectedTheme = LineupTheme.velvet.rawValue

    var body: some View {
        Group {
            if library.hasProfile || media.hasProfile {
                MainView()
            } else {
                InitialSourceSetupView()
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

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveView(isActive: selectedTab == 0)
                .tabItem { Label("Live", systemImage: "play.rectangle.fill") }
                .tag(0)
            GuideView()
                .tabItem { Label("Guide", systemImage: "list.bullet.rectangle") }
                .tag(1)
            MediaServersView()
                .tabItem { Label("Media Servers", systemImage: "play.square.stack") }
                .tag(2)
            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(3)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .tint(LineupStyle.highlight)
    }
}
#endif
