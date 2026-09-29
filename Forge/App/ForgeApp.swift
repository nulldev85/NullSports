import SwiftUI

@main
struct ForgeApp: App {
    @State private var launcher = AppLauncher()

    init() {
        AppAppearance.apply()
        if ProcessInfo.processInfo.arguments.contains("-ForgeUITest") {
            // Keeps UI tests fast and deterministic.
            UIView.setAnimationsEnabled(false)
            // Records any main-thread stall, for the CI report.
            StallMonitor.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            LaunchView(launcher: launcher)
                .task { await launcher.launch() }
        }
    }
}

struct LaunchView: View {
    let launcher: AppLauncher

    var body: some View {
        switch launcher.state {
        case .loading:
            LaunchPlaceholder()
                .transition(.opacity)
        case .ready(let model):
            RootView()
                .environment(model)
                .transition(.opacity)
        case .failed(let message):
            LaunchFailureView(message: message) {
                Task { await launcher.launch() }
            }
            .transition(.opacity)
        }
    }
}

/// Continues the launch screen (a plain canvas) while data loads, then the
/// app fades in. The mark and a spinner only appear if loading is slow, so a
/// normal launch never flashes them.
struct LaunchPlaceholder: View {
    @State private var showsProgress = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.accentColor)
            ProgressView()
        }
        .opacity(showsProgress ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(Motion.gentle) { showsProgress = true }
        }
    }
}

/// Shown only if the database can't be opened at all (for example, the
/// device is out of storage). Nothing is deleted; retrying is always safe.
struct LaunchFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text("Forge couldn't open your data")
                .font(.app(.title2, .semibold))
                .multilineTextAlignment(.center)
            Text("Your workouts are still on this iPhone — nothing has been deleted. This usually means the device is out of storage. Free up some space and try again.")
                .font(.app(.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.num(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            Button("Try Again", action: retry)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
