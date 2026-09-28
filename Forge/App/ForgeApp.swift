import SwiftUI

@main
struct ForgeApp: App {
    @State private var launcher = AppLauncher()

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
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
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
                .foregroundStyle(.orange)
            Text("Forge couldn't open your data")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Your workouts are still on this iPhone — nothing has been deleted. This usually means the device is out of storage. Free up some space and try again.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            Button("Try Again", action: retry)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
