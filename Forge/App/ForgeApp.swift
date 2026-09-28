import SwiftUI

@main
struct ForgeApp: App {
    @State private var launcher = AppLauncher()

    init() {
        AppAppearance.apply()
        if ProcessInfo.processInfo.arguments.contains("-ForgeUITest") {
            // Keeps UI tests fast and deterministic.
            UIView.setAnimationsEnabled(false)
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
            VStack(spacing: 16) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        case .ready(let model):
            RootView()
                .environment(model)
        case .failed(let message):
            LaunchFailureView(message: message) {
                Task { await launcher.launch() }
            }
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
