import Foundation
import UserNotifications

/// Local notifications for when the app isn't in the foreground: "rest is
/// over" and "timer finished". Everything stays on the device.
@MainActor
final class Notifier {
    private let center = UNUserNotificationCenter.current()
    private var requested = false
    /// UI tests must never be interrupted by the permission prompt.
    private let disabled = ProcessInfo.processInfo.arguments.contains("-ForgeUITest")

    enum Identifier {
        static let rest = "forge.rest"
        static let timer = "forge.timer"
        static let set = "forge.set"
    }

    func requestAuthorizationIfNeeded() {
        guard !requested, !disabled else { return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func scheduleRestEnd(at date: Date, exerciseName: String) {
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest complete"
        content.body = exerciseName.isEmpty ? "Time for your next set." : "Time for your next set of \(exerciseName)."
        content.sound = .default
        schedule(Identifier.rest, content: content, after: interval)
    }

    func cancelRestEnd() {
        center.removePendingNotificationRequests(withIdentifiers: [Identifier.rest])
    }

    /// A timed set's countdown reaching zero.
    func scheduleSetEnd(at date: Date, exerciseName: String) {
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = exerciseName.isEmpty ? "That set is done." : "That set of \(exerciseName) is done."
        content.sound = .default
        schedule(Identifier.set, content: content, after: interval)
    }

    func cancelSetEnd() {
        center.removePendingNotificationRequests(withIdentifiers: [Identifier.set])
    }

    func scheduleTimerEnd(at date: Date, title: String) {
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(title) finished"
        content.body = "Nice work. Open Forge to save the result."
        content.sound = .default
        schedule(Identifier.timer, content: content, after: interval)
    }

    func cancelTimerEnd() {
        center.removePendingNotificationRequests(withIdentifiers: [Identifier.timer])
    }

    private func schedule(_ identifier: String, content: UNMutableNotificationContent, after interval: TimeInterval) {
        guard !disabled else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.add(request) { _ in }
    }
}
