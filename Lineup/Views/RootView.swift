import SwiftUI
import Foundation
import Observation

struct RootView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(\.scenePhase) private var scenePhase
    /// Watched so the app's tint follows the accent; the tabs below redraw
    /// themselves for it.
    @AppStorage(LineupAccent.storageKey) private var accent = LineupAccent.red.hex
    #if os(iOS)
    /// An Apple TV's setup code, opened from the Camera app.
    @State private var incomingSetup: DeviceSetupPairing?
    #endif

    var body: some View {
        Group {
            if library.hasProfile || media.hasProfile {
                MainView()
            } else {
                #if os(iOS)
                MobileWelcomeView().lineupAccentScope(accent)
                #else
                InitialSourceSetupView().lineupAccentScope(accent)
                #endif
            }
        }
        .foregroundStyle(LineupStyle.text)
        .tint(LineupStyle.highlight)
        .background(LineupStyle.background.ignoresSafeArea())
        #if os(iOS)
        .onOpenURL { url in
            if let pairing = DeviceSetupPairing(url: url) { incomingSetup = pairing }
        }
        .lineupSheet(item: $incomingSetup) { pairing in
            MobileDeviceSetupSheet(pairing: pairing).environment(library).environment(media)
        }
        #endif
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
        #if os(iOS)
        .onChange(of: scenePhase, initial: true) { _, phase in
            library.setPreparationSuspended(phase == .background)
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && library.hasProfile && !library.streams.isEmpty {
                library.refreshSchedule()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                library.refreshProviderIfNeeded()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            if library.hasProfile { library.refreshSchedule() }
        }
        // Every refresh of the scores is looked at for the viewer's teams:
        // a game starting, close at the end, or going to overtime is held
        // for a player to show over the picture.
        .onChange(of: library.gamesRevision, initial: true) {
            GameAlertCenter.shared.observe(library.gamesByLeague.values.flatMap { $0 }, isFollowing: library.isFollowing)
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
/// app was relaunched. Tracking each page and stating the answer on
/// every tab means a page closing is a change of state the bar follows,
/// and the Library's own screen puts it back whenever it shows.
@MainActor @Observable
final class TVTabBarState {
    private(set) var hidden = false
    @ObservationIgnored private var pagesOpen: Set<UUID> = []

    func pageAppeared(_ id: UUID) { pagesOpen.insert(id); sync() }
    func pageDisappeared(_ id: UUID) { pagesOpen.remove(id); sync() }
    /// A tab's own screen is showing: no page is over it.
    func reset() { pagesOpen.removeAll(); sync() }

    private func sync() {
        let hide = !pagesOpen.isEmpty
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
    @State private var tabBar = TVTabBarState()
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
                .environment(\.tvPlaybackPlace, .sports)
                .lineupAccentScope(accent)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("Sports", systemImage: selectedTab == 0 ? "play.rectangle.fill" : "play.rectangle") }
                .tag(0)
            GuideView(isActive: selectedTab == 1)
                .environment(\.tvPlaybackPlace, .guide)
                .lineupAccentScope(accent)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("TV Guide", systemImage: selectedTab == 1 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle") }
                .tag(1)
            MediaServersView()
                .environment(\.tvPlaybackPlace, .library)
                .lineupAccentScope(accent)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("Library", systemImage: selectedTab == 2 ? "play.square.stack.fill" : "play.square.stack") }
                .tag(2)
            // Everything at once -- the Library, live TV, the guide and VOD --
            // each result saying which of the other tabs it lives in.
            AppSearchView()
                .environment(\.tvPlaybackPlace, .search)
                .lineupAccentScope(accent)
                .tabBar(hidden: tabBar.hidden)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(4)
            // Not rebuilt for a new accent: the accent is chosen here, and
            // rebuilding would throw the remote off the swatch it is on.
            AccountView(selectedTab: $selectedTab)
                .environment(\.tvPlaybackPlace, .library)
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
        .overlay(alignment: .topTrailing) {
            if selectedTab == 1 { DataRefreshPopup() }
        }
    }
}
#endif
