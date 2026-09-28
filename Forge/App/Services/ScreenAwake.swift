import UIKit

/// Keeps the screen from dimming while any part of the app needs it (a
/// running timer, the workout screen) and restores normal behavior once
/// none do.
@MainActor
enum ScreenAwake {
    private static var reasons: Set<String> = []

    static func hold(_ reason: String) {
        reasons.insert(reason)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release(_ reason: String) {
        reasons.remove(reason)
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}

/// Asks iOS for extra time to finish work that may still be running when
/// the app moves to the background. Call `end()` when done.
@MainActor
final class BackgroundTaskToken {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Runs work that must finish even if the app is being backgrounded
/// (snapshots, checkpoints) off the main thread.
@MainActor
enum BackgroundWork {
    static func run(_ name: String, _ work: @escaping @Sendable () -> Void) {
        let token = BackgroundTaskToken(name: name)
        Task {
            await Task.detached(priority: .utility) {
                work()
            }.value
            token.end()
        }
    }
}

/// Runs `work` on the main actor after a short delay (used to sequence
/// sheet dismissals and presentations).
@MainActor
func afterDelay(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        work()
    }
}
