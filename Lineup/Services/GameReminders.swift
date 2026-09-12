import Foundation
import UserNotifications

struct FollowedTeam: Codable, Hashable, Identifiable {
    let league: SportsLeague
    let abbreviation: String
    let name: String

    var id: String { "\(league.rawValue):\(abbreviation)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class GameReminders: ObservableObject {
    static let shared = GameReminders()

    @Published private(set) var followedTeams: Set<FollowedTeam> = []
    @Published private(set) var manualGameIDs: Set<String> = []
    @Published private(set) var authorizationMessage: String?

    private let defaults = UserDefaults.standard
    private let teamsKey = "Lineup.followedTeams"
    private let gamesKey = "Lineup.manualGameReminders"
    private let notificationPrefix = "lineup.game."
    private var knownGames: [SportsGame] = []

    private init() { restore() }

    func restore() {
        followedTeams = []
        manualGameIDs = []
        if let data = defaults.data(forKey: teamsKey),
           let teams = try? JSONDecoder().decode(Set<FollowedTeam>.self, from: data) {
            followedTeams = teams
        }
        if let data = defaults.data(forKey: gamesKey),
           let games = try? JSONDecoder().decode(Set<String>.self, from: data) {
            manualGameIDs = games
        }
        if !followedTeams.isEmpty || !manualGameIDs.isEmpty {
            Task { await requestPermissionAndReschedule() }
        } else {
            Task { await reschedule() }
        }
    }

    func availableTeams(in games: [SportsGame]) -> [FollowedTeam] {
        let current = games.flatMap { game in
            [FollowedTeam(league: game.league, abbreviation: game.awayAbbreviation, name: game.awayTeam),
             FollowedTeam(league: game.league, abbreviation: game.homeAbbreviation, name: game.homeTeam)]
        }
        return Array(Set(current).union(followedTeams)).sorted {
            $0.league.rawValue == $1.league.rawValue ? $0.name < $1.name : $0.league.rawValue < $1.league.rawValue
        }
    }

    func follows(_ team: FollowedTeam) -> Bool { followedTeams.contains(team) }
    func reminds(_ game: SportsGame) -> Bool { manualGameIDs.contains(game.id) }

    func toggleTeam(_ team: FollowedTeam) {
        if !followedTeams.insert(team).inserted { followedTeams.remove(team) }
        persist()
        Task { await requestPermissionAndReschedule() }
    }

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
        defaults.set(try? JSONEncoder().encode(followedTeams), forKey: teamsKey)
        defaults.set(try? JSONEncoder().encode(manualGameIDs), forKey: gamesKey)
        CloudSettingsSync.shared.localSettingsChanged()
    }

    private func requestPermissionAndReschedule() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            authorizationMessage = granted ? nil : "Enable Lineup notifications in device settings to receive reminders."
        } catch {
            authorizationMessage = "Notification permission could not be requested."
        }
        await reschedule()
    }

    private func reschedule() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        // Keep previously scheduled alerts until the app has a usable schedule.
        guard !knownGames.isEmpty else { return }
        let now = Date()
        let upcoming = knownGames.filter { game in
            game.isUpcoming && (manualGameIDs.contains(game.id) || followedTeams.contains {
                $0.league == game.league && ($0.abbreviation == game.awayAbbreviation || $0.abbreviation == game.homeAbbreviation)
            })
        }
        let wanted = Set(upcoming.map { notificationPrefix + $0.id })
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(notificationPrefix) && !wanted.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for game in upcoming {
            let fireDate = game.start.addingTimeInterval(-15 * 60)
            guard fireDate > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(game.awayTeam) at \(game.homeTeam)"
            content.body = "Starts at \(game.start.formatted(date: .omitted, time: .shortened)) in Lineup."
            content.sound = .default
            content.userInfo = ["gameID": game.id]
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: notificationPrefix + game.id,
                content: content, trigger: trigger))
        }
    }
}
