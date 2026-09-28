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

/// Runs work that must finish even if the app is being backgrounded
/// (snapshots, exports), asking iOS for extra time to do so.
@MainActor
enum BackgroundWork {
    private final class Token: @unchecked Sendable {
        var identifier: UIBackgroundTaskIdentifier = .invalid
    }

    static func run(_ name: String, _ work: @escaping @Sendable () -> Void) {
        let token = Token()
        token.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { end(token) }
        }
        Task.detached(priority: .utility) {
            work()
            await MainActor.run { end(token) }
        }
    }

    private static func end(_ token: Token) {
        guard token.identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token.identifier)
        token.identifier = .invalid
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
