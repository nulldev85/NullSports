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
            if (library.hasProfile || media.hasProfile) && !DeviceSetupHold.shared.keepsWelcome {
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
        .onAppear {
            applyLineupTabBarTheme()
            // Every moment the screen stands still, kept for Settings.
            FrameStallMonitor.shared.refresh = library.refreshProgress
            FrameStallMonitor.shared.start()
        }
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
            let games = library.followedTeams.isEmpty ? [] : library.gamesByLeague.values.flatMap { $0 }
            GameAlertCenter.shared.observe(games, isFollowing: library.isFollowing)
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

private struct TVTabIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var tvTabIsActive: Bool {
        get { self[TVTabIsActiveKey.self] }
        set { self[TVTabIsActiveKey.self] = newValue }
    }
    var tvTabBar: TVTabBarState? {
        get { self[TVTabBarStateKey.self] }
        set { self[TVTabBarStateKey.self] = newValue }
    }
}

/// Takes the remote up to the tabs: what Back does at the top of a tab.
private struct TVShowTabsKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var tvShowTabs: (() -> Void)? {
        get { self[TVShowTabsKey.self] }
        set { self[TVShowTabsKey.self] = newValue }
    }
}

private struct TVBackToTabs: ViewModifier {
    @Environment(\.tvShowTabs) private var showTabs
    func body(content: Content) -> some View { content.onExitCommand(perform: showTabs) }
}

extension View {
    /// Back from a tab's own screen goes up to the tabs, as it did with the
    /// system's tab bar. Put on a tab's root screen, inside any navigation
    /// stack, so a page opened over it still goes back to the screen.
    func tvBackToTabs() -> some View { modifier(TVBackToTabs()) }
}

/// One of the tabs along the top.
private struct TVTabItem: Identifiable {
    let tag: Int
    let title: String
    let symbol: String
    let chosenSymbol: String
    var id: Int { tag }
}

/// The tabs along the top, drawn by Lineup rather than by tvOS, whose own bar
/// paints a white plate behind the tab the remote is on. Here, as everywhere
/// in the app, the tab under the remote rises, larger and with a shadow under
/// it; the chosen one is the bright one.
private struct TVTabStrip: View {
    let tabs: [TVTabItem]
    let selection: Int
    var focus: FocusState<Int?>.Binding
    let choose: (Int) -> Void

    var body: some View {
        HStack(spacing: 18) {
            ForEach(tabs) { tab in
                let chosen = selection == tab.tag
                let focused = focus.wrappedValue == tab.tag
                HStack(spacing: 12) {
                    Image(systemName: chosen ? tab.chosenSymbol : tab.symbol)
                        .font(.system(size: 26, weight: .semibold))
                    Text(tab.title).font(.inter(27, chosen || focused ? .bold : .semibold))
                }
                .foregroundStyle(chosen || focused ? Color.white : Color.white.opacity(0.55))
                .padding(.horizontal, 24).padding(.vertical, 14)
                .contentShape(Rectangle())
                .focusable()
                .focused(focus, equals: tab.tag)
                .focusEffectDisabled()
                .tvSelectAction { choose(tab.tag) }
                .scaleEffect(focused ? 1.14 : 1)
                .offset(y: focused ? -7 : 0)
                .lineupShadow(.lifted, on: focused)
                .zIndex(focused ? 1 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: focused)
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: chosen)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.top, 24).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .focusSection()
        // Up into the tabs lands on the tab already chosen, not the one
        // nearest the card the remote left: that was often Library, and
        // landing on a tab opens it.
        .defaultFocus(focus, selection, priority: .userInitiated)
    }
}

private final class TVTabsLeft {
    var at: TimeInterval = 0
}

struct MainView: View {
    @State private var selectedTab: Int
    @State private var tabBar = TVTabBarState()
    /// The tabs opened so far. Each is kept once opened, as the system's tab
    /// view kept them, so coming back to one finds it as it was left.
    @State private var opened: Set<Int>
    @FocusState private var tabFocus: Int?
    /// When the remote last left the tabs. Not observed: nothing is drawn
    /// from it.
    @State private var tabsLeft = TVTabsLeft()
    /// The accent chosen on the phone, which iCloud brings here: the tabs
    /// are drawn again in it when it changes, as the phone's are.
    @AppStorage(LineupAccent.storageKey) private var accent = LineupAccent.red.hex

    private static let tabs = [
        TVTabItem(tag: 0, title: "Sports", symbol: "play.rectangle", chosenSymbol: "play.rectangle.fill"),
        TVTabItem(tag: 1, title: "TV Guide", symbol: "list.bullet.rectangle", chosenSymbol: "list.bullet.rectangle.fill"),
        TVTabItem(tag: 2, title: "Library", symbol: "play.square.stack", chosenSymbol: "play.square.stack.fill"),
        TVTabItem(tag: 4, title: "Search", symbol: "magnifyingglass", chosenSymbol: "magnifyingglass"),
        TVTabItem(tag: 3, title: "Settings", symbol: "person.crop.circle", chosenSymbol: "person.crop.circle.fill")
    ]

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
        _opened = State(initialValue: [initialTab])
    }

    var body: some View {
        // The tabs are Lineup's primary navigation, so they stay up; only a
        // title's page takes them away (`TVTabBarState`).
        VStack(spacing: 0) {
            if !tabBar.hidden {
                TVTabStrip(tabs: Self.tabs, selection: selectedTab, focus: $tabFocus) { selectedTab = $0 }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ZStack {
                ForEach(Self.tabs) { tab in
                    if opened.contains(tab.tag) {
                        let shown = selectedTab == tab.tag
                        page(tab.tag)
                            .opacity(shown ? 1 : 0)
                            // A tab out of sight takes no focus and no taps.
                            .disabled(!shown)
                            .accessibilityHidden(!shown)
                            .zIndex(shown ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: tabBar.hidden)
        .environment(\.tvTabBar, tabBar)
        .environment(\.tvShowTabs, { tabFocus = selectedTab })
        // Every tab sits on the same plain ground under the same tabs.
        .background(LineupStyle.background.ignoresSafeArea())
        // Moving along the tabs shows each one, as the system's tabs did.
        .onChange(of: tabFocus) { from, tab in
            let now = ProcessInfo.processInfo.systemUptime
            guard let tab else { tabsLeft.at = now; return }
            guard tab != selectedTab else { return }
            // Coming up from a tab's screen is never a choice of another
            // tab, wherever the focus engine put the remote; moving along
            // the tabs is. A move along them can pass through no tab for
            // an instant, so only a remote that has been away a while is
            // coming up from below.
            guard from != nil || now - tabsLeft.at < 0.2 else { tabFocus = selectedTab; return }
            selectedTab = tab
        }
        // A tab changed is a tab's own screen showing.
        .onChange(of: selectedTab, initial: true) { _, tab in
            opened.insert(tab)
            tabBar.reset()
            FrameStallMonitor.shared.tab = [0: "Sports", 1: "TV Guide", 2: "Library", 3: "Settings", 4: "Search"][tab] ?? "Tab \(tab)"
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .tint(.white)
        // Beside the tabs, where the set's own notices appear, over every
        // tab. A player covers it: they are all full-screen presentations.
        .overlay(alignment: .topTrailing) {
            if selectedTab == 1 { DataRefreshPopup() }
        }
    }

    @ViewBuilder
    private func page(_ tag: Int) -> some View {
        switch tag {
        case 0:
            LiveView(isActive: selectedTab == 0)
                .environment(\.tvPlaybackPlace, .sports)
                .lineupAccentScope(accent)
                .tvBackToTabs()
        case 1:
            GuideView(isActive: selectedTab == 1)
                .environment(\.tvPlaybackPlace, .guide)
                .lineupAccentScope(accent)
        case 2:
            MediaServersView()
                .environment(\.tvTabIsActive, selectedTab == 2)
                .environment(\.tvPlaybackPlace, .library)
                .lineupAccentScope(accent)
        case 4:
            // Everything at once -- the Library, live TV, the guide and VOD --
            // each result saying which of the other tabs it lives in.
            AppSearchView()
                .environment(\.tvPlaybackPlace, .search)
                .lineupAccentScope(accent)
        default:
            // Not rebuilt for a new accent: the accent is chosen here, and
            // rebuilding would throw the remote off the swatch it is on.
            AccountView(selectedTab: $selectedTab)
                .environment(\.tvTabIsActive, selectedTab == 3)
                .environment(\.tvPlaybackPlace, .library)
        }
    }
}
#endif

#if !os(tvOS)
extension View {
    /// Only the television's tabs are reached with Back.
    func tvBackToTabs() -> some View { self }
}
#endif
