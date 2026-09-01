import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: SportsLibrary

    var body: some View {
        Group {
            if library.hasProfile {
                MainView()
            } else {
                ProfileSetupView()
            }
        }
        .background(NullSportsStyle.background.ignoresSafeArea())
        .task {
            if library.hasProfile && library.streams.isEmpty { await library.reload() }
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
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "play.rectangle.fill") }
            LeaguesView()
                .tabItem { Label("Leagues", systemImage: "sportscourt.fill") }
            GuideView()
                .tabItem { Label("Guide", systemImage: "list.bullet.rectangle") }
            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .tint(NullSportsStyle.field)
    }
}

