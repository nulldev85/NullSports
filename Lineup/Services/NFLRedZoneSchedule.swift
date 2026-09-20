import Foundation

/// Builds the one NFL broadcast the score feed cannot: RedZone is a channel,
/// not a fixture, so it has no away/home game of its own in the schedule API.
enum NFLRedZoneSchedule {
    private static var easternCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    static func event(for games: [SportsGame]) -> SportsGame? {
        let calendar = easternCalendar
        let sundayDaytime = games.filter { game in
            guard game.league == .nfl,
                  calendar.component(.weekday, from: game.start) == 1 else { return false }
            let hour = calendar.component(.hour, from: game.start)
            return (12...17).contains(hour)
        }

        // A normal regular-season Sunday has two crowded afternoon windows.
        // Requiring four games avoids inventing RedZone during the playoffs,
        // isolated international games, or a sparse preseason slate.
        guard sundayDaytime.count >= 4,
              let sunday = sundayDaytime.map(\.start).min() else { return nil }
        let day = calendar.dateComponents([.year, .month, .day], from: sunday)
        guard let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: day.year, month: day.month, day: day.day,
            hour: 13, minute: 0, second: 0
        )) else { return nil }

        let identifier = String(format: "%04d%02d%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return SportsGame(
            id: "nfl-redzone-\(identifier)", league: .nfl, start: start,
            awayTeam: "NFL", homeTeam: "RedZone",
            awayAbbreviation: "NFL", homeAbbreviation: "RZ",
            awayLogo: "", homeLogo: "", awayScore: "", homeScore: "",
            awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil,
            venue: nil, location: nil,
            status: "Sundays · 1:00 PM ET", state: "pre",
            broadcast: "NFL RedZone", eventName: "NFL RedZone"
        )
    }
}
