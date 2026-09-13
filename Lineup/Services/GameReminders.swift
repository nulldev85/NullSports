import Foundation
import UserNotifications

@MainActor
final class GameReminders: ObservableObject {
    static let shared = GameReminders()

    @Published private(set) var manualGameIDs: Set<String> = []
    @Published private(set) var authorizationMessage: String?

    private let defaults = UserDefaults.standard
    private let oldTeamsKey = "Lineup.followedTeams"
    private let gamesKey = "Lineup.manualGameReminders"
    private let notificationPrefix = "lineup.game."
    private var knownGames: [SportsGame] = []

    private init() { restore() }

    func restore() {
        defaults.removeObject(forKey: oldTeamsKey)
        manualGameIDs = []
        if let data = defaults.data(forKey: gamesKey),
           let games = try? JSONDecoder().decode(Set<String>.self, from: data) {
            manualGameIDs = games
        }
        Task {
            await removeUnselectedPendingRequests()
            if !manualGameIDs.isEmpty { await requestPermissionAndReschedule() }
            else { await reschedule() }
        }
    }

    func reminds(_ game: SportsGame) -> Bool { manualGameIDs.contains(game.id) }

    func toggleGame(_ game: SportsGame) {
        if !manualGameIDs.insert(game.id).inserted { manualGameIDs.remove(game.id) }
        persist()
        Task { await requestPermissionAndReschedule() }
    }

    func updateGames(_ games: [SportsGame]) {
        knownGames = games
        Task { await reschedule() }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(manualGameIDs), forKey: gamesKey)
        CloudSettingsSync.shared.localSettingsChanged()
    }

    private func requestPermissionAndReschedule() async {
        do {
            #if os(tvOS)
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
            #else
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            #endif
            authorizationMessage = granted ? nil : "Enable Lineup notifications in device settings to receive reminders."
        } catch {
            authorizationMessage = "Notification permission could not be requested."
        }
        await reschedule()
    }

    private func removeUnselectedPendingRequests() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let selected = Set(manualGameIDs.map { notificationPrefix + $0 })
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(notificationPrefix) && !selected.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
    }

    private func reschedule() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        // Keep previously scheduled alerts until the app has a usable schedule.
        guard !knownGames.isEmpty else { return }
        let now = Date()
        let upcoming = knownGames.filter { game in
            game.isUpcoming && manualGameIDs.contains(game.id)
        }
        let wanted = Set(upcoming.map { notificationPrefix + $0.id })
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(notificationPrefix) && !wanted.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for game in upcoming {
            let fireDate = game.start.addingTimeInterval(-15 * 60)
            guard fireDate > now else { continue }
            let content = UNMutableNotificationContent()
            #if os(tvOS)
            content.badge = 1
            #else
            content.title = "\(game.awayTeam) at \(game.homeTeam)"
            content.body = "Starts at \(game.start.formatted(date: .omitted, time: .shortened)) in Lineup."
            content.sound = .default
            content.userInfo = ["gameID": game.id]
            #endif
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: notificationPrefix + game.id,
                content: content, trigger: trigger))
        }
    }
}
