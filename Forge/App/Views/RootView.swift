import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        @Bindable var session = app.session
        @Bindable var timers = app.timers
        TabView(selection: $app.selectedTab) {
            TrainView()
                .tabItem { Label("Train", systemImage: "dumbbell.fill") }
                .tag(AppTab.train)
            TimersView()
                .tabItem { Label("Timers", systemImage: "timer") }
                .tag(AppTab.timers)
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(AppTab.history)
            ExerciseLibraryView()
                .tabItem { Label("Exercises", systemImage: "list.bullet.rectangle.portrait") }
                .tag(AppTab.exercises)
            ProgressDashboardView()
                .tabItem { Label("Progress", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.progress)
        }
        .tint(app.settings.accentColor)
        .preferredColorScheme(app.settings.colorScheme)
        .fullScreenCover(isPresented: $session.isPresented) {
            WorkoutView()
                .environment(app)
                .tint(app.settings.accentColor)
                .preferredColorScheme(app.settings.colorScheme)
                .toastOverlay(app.feedback)
        }
        .fullScreenCover(isPresented: $timers.isPresented) {
            if let controller = app.timers.active {
                StandaloneTimerScreen(controller: controller)
                    .environment(app)
                    .tint(app.settings.accentColor)
                    .toastOverlay(app.feedback)
            }
        }
        .sheet(item: $session.finishedSummary) { summary in
            WorkoutSummaryView(summary: summary)
                .environment(app)
                .tint(app.settings.accentColor)
        }
        .toastOverlay(app.feedback)
        .onChange(of: scenePhase) { _, phase in
            app.handle(phase)
        }
        .alert("About your data", isPresented: Binding(
            get: { app.launchNotice != nil },
            set: { if !$0 { app.launchNotice = nil } }
        )) {
            Button("OK", role: .cancel) { app.launchNotice = nil }
        } message: {
            Text(app.launchNotice ?? "")
        }
    }
}

extension View {
    func toastOverlay(_ feedback: Feedback) -> some View {
        overlay(alignment: .top) {
            if let toast = feedback.toast {
                ToastBanner(toast: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { feedback.dismiss() }
                    .zIndex(10)
            }
        }
    }

    /// Adds the "workout in progress" bar above the tab bar.
    func activeWorkoutInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            ActiveWorkoutBar()
        }
    }
}

struct ActiveWorkoutBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let workout = app.session.workout, !app.session.isPresented {
            Button {
                app.session.isPresented = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(workout.startedAt, style: .timer)
                                .monospacedDigit()
                            if let rest = app.session.rest, rest.remaining(at: app.session.clock) > 0 {
                                Text("· Rest \(DurationFormat.countdownClock(rest.remaining(at: app.session.clock)))")
                                    .monospacedDigit()
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Resume")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("resumeWorkoutBar")
        }
    }
}
