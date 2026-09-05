import SwiftUI
import Foundation

struct RootView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var launchRefreshActive = false

    var body: some View {
        Group {
            if library.hasProfile {
                MainView()
            } else {
                ProfileSetupView()
            }
        }
        .background(NullSportsStyle.background.ignoresSafeArea())
        .overlay {
            if launchRefreshActive {
                LaunchRefreshIndicator()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .task {
            guard library.hasProfile else { return }
            launchRefreshActive = true
            if library.streams.isEmpty { await library.bootstrap() }
            else { library.refreshSchedule() }
            while library.isLoading || library.isGuideLoading || library.isScheduleLoading {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeOut(duration: 0.25)) { launchRefreshActive = false }
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

private struct LaunchRefreshIndicator: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(NullSportsStyle.live)
                .frame(width: 10, height: 10)
                .scaleEffect(pulsing ? 1.22 : 0.82)
                .opacity(pulsing ? 1 : 0.52)
            Text("Refreshing Data…")
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(NullSportsStyle.text)
        .padding(.horizontal, 24)
        .frame(height: 52)
        .background(NullSportsStyle.surface.opacity(0.96))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(NullSportsStyle.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
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
        .tint(NullSportsStyle.field)
    }
}
