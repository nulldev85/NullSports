import SwiftUI
import Foundation

struct RootView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if library.hasProfile {
                MainView()
            } else {
                ProfileSetupView()
            }
        }
        .foregroundStyle(NullSportsStyle.text)
        .tint(NullSportsStyle.lightPurple)
        .background(NullSportsStyle.background.ignoresSafeArea())
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
            Text(library.errorMessage ?? "Unknown error")
        }
    }
}

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
            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(2)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .tint(NullSportsStyle.field)
    }
}
