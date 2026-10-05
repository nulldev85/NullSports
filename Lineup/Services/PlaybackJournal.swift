import Foundation
import Combine

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func note(_ text: String, at date: Date = Date()) {
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
