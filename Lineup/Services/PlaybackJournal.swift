import Foundation
import Combine
import UIKit

/// What the player did, and when, kept between launches so it can be read
/// after the fact.
///
/// "It stopped and went back to the menu" can be the screen saver, a stream
/// that dropped and could not be reopened, a film that ended early, the
/// remote, or tvOS closing the app while the television slept. Each leaves a
/// different trail here, and the Account tab shows it on the television
/// itself, without a device log.
///
/// It says what happened, never where from: a stream's address carries the
/// provider's password, and a media server's carries its key.
@MainActor
final class PlaybackJournal: ObservableObject {
    static let shared = PlaybackJournal()

    struct Entry: Codable, Equatable {
        let at: Date
        let text: String
    }

    /// A few evenings of watching, and small enough for the settings store,
    /// which is all the lasting room an Apple TV app is given.
    static let limit = 300
    static let storageKey = "Lineup.playbackJournal.v1"

    @Published private(set) var entries: [Entry] = []
    private let defaults: UserDefaults
    /// Whether the app was on screen, kept as it changes: still set at the
    /// next launch, the app didn't leave by going to the background. It
    /// crashed, or tvOS ended it, most often for using too much memory.
    private static let inFrontKey = "Lineup.playbackJournal.inFront.v1"
    /// What was playing, for saying so if the app goes down with it.
    private static let watchingKey = "Lineup.playbackJournal.watching.v1"
    /// While something plays, a note every few minutes of the memory in use:
    /// where the trail ends says when the app went, and whether it was
    /// climbing.
    private static let heartbeatInterval: Duration = .seconds(5 * 60)
    private var heartbeat: Task<Void, Never>?
    private var memoryWarnings: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// At launch: says if the last run ended without leaving the screen,
    /// then that the app opened, and listens for tvOS's memory warnings.
    func appLaunched() {
        if defaults.bool(forKey: Self.inFrontKey) {
            let watching = defaults.string(forKey: Self.watchingKey)
            note(watching.map { "Lineup closed unexpectedly while watching \($0)" }
                 ?? "Lineup closed unexpectedly")
        }
        defaults.removeObject(forKey: Self.watchingKey)
        note("Lineup opened, \(Self.memoryInUse) in use")
        defaults.set(true, forKey: Self.inFrontKey)
        guard memoryWarnings == nil else { return }
        memoryWarnings = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                PlaybackJournal.shared.note("Memory warning from tvOS, \(PlaybackJournal.memoryInUse) in use")
            }
        }
    }

    /// The app came to the front or left it. Ended in the background, a run
    /// is tvOS tidying up, not something going wrong.
    func appInFront(_ inFront: Bool) {
        defaults.set(inFront, forKey: Self.inFrontKey)
    }

    /// The memory the app is using, as tvOS counts it when deciding whether
    /// to end it.
    nonisolated static var memoryInUse: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "unknown memory" }
        return "\(info.phys_footprint / 1_048_576) MB"
    }

    private func followPlayback(_ text: String) {
        if text.hasPrefix("Watching ") || text.hasPrefix("Changed channel to ") {
            let title = text.hasPrefix("Watching ") ? String(text.dropFirst("Watching ".count))
                : String(text.dropFirst("Changed channel to ".count))
            defaults.set(title, forKey: Self.watchingKey)
            guard heartbeat == nil else { return }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: Self.heartbeatInterval) } catch { return }
                    self?.note("Still playing, \(Self.memoryInUse) in use")
                }
            }
        } else if text.hasPrefix("Closed") || text.hasPrefix("Split screen closed") {
            defaults.removeObject(forKey: Self.watchingKey)
            heartbeat?.cancel()
            heartbeat = nil
        }
    }

    func note(_ text: String, at date: Date = Date()) {
        followPlayback(text)
        entries.append(Entry(at: date, text: text))
        // The oldest go first: the trail that matters is the latest one.
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// One day's entries, newest first, under the day's name.
    struct Day: Identifiable {
        let name: String
        var entries: [Entry]
        var id: String { name }
    }

    /// Newest first, under the day each happened on.
    var days: [Day] {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        var days: [Day] = []
        for entry in entries.reversed() {
            let name = formatter.string(from: entry.at)
            if days.last?.name == name {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(Day(name: name, entries: [entry]))
            }
        }
        return days
    }

    /// The time of day an entry happened, to the second.
    static func time(of entry: Entry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.at)
    }

    /// A position in a film as a person reads it: "1:02:03", or "4:05".
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.storageKey)
    }
}
