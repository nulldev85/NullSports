import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        @Bindable var session = app.session
        @Bindable var timers = app.timers
        // The workout-in-progress bar wraps each tab's whole navigation
        // stack, so it stays visible on every screen pushed inside it.
        TabView(selection: $app.selectedTab) {
            TrainView()
                .activeWorkoutInset()
                .tabItem { Label("Train", systemImage: "dumbbell.fill") }
                .tag(AppTab.train)
            TimersView()
                .activeWorkoutInset()
                .tabItem { Label("Timers", systemImage: "timer") }
                .tag(AppTab.timers)
            HistoryView()
                .activeWorkoutInset()
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(AppTab.history)
            ExerciseLibraryView()
                .activeWorkoutInset()
                .tabItem { Label("Exercises", systemImage: "list.bullet.rectangle.portrait") }
                .tag(AppTab.exercises)
            ProgressDashboardView()
                .activeWorkoutInset()
                .tabItem { Label("Progress", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.progress)
        }
        .themed(app.settings)
        .fullScreenCover(isPresented: $session.isPresented) {
            WorkoutView()
                .environment(app)
                .themed(app.settings)
                .toastOverlay(app.feedback)
        }
        .fullScreenCover(isPresented: $timers.isPresented) {
            if let controller = app.timers.active {
                StandaloneTimerScreen(controller: controller)
                    .environment(app)
                    .themed(app.settings, scheme: .dark)
                    .toastOverlay(app.feedback)
            }
        }
        .sheet(item: $session.finishedSummary) { summary in
            WorkoutSummaryView(summary: summary)
                .environment(app)
                .themed(app.settings)
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
    /// Applies the athlete's accent color and appearance. `accentColor` is
    /// set alongside `tint` so custom drawing that uses `Color.accentColor`
    /// follows the chosen color too.
    /// `scheme` overrides the athlete's appearance (the timers are always dark).
    func themed(_ settings: SettingsStore, scheme: ColorScheme? = nil) -> some View {
        tint(settings.accentColor)
            .accentColor(settings.accentColor)
            .font(.app(.body))
            .preferredColorScheme(scheme ?? settings.colorScheme)
    }

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
                        .font(.app(.title3, .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.name)
                            .font(.app(.subheadline, .semibold))
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
                            if let timer = app.session.timedRun, !timer.run.isFinished {
                                Text("· \(timer.program.config.kind.displayName) \(timer.clockText)")
                                    .monospacedDigit()
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Resume")
                        .font(.app(.subheadline, .semibold))
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
