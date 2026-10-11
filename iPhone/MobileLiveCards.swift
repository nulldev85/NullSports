import SwiftUI

// The Live tab's cards: a score tile for a game on now, a row for one still
// to come, and the strip under a game being previewed.

/// What the Live tab shows: the games on now, the ones still to come, or the
/// viewer's own teams. One at a time, switched rather than scrolled past.
enum MobileLiveSegment: Hashable {
    case live, upNext, mine
}

/// A team's colour from the schedule, which gives it as hex with or without
/// the hash.
func mobileTeamColor(_ hex: String?) -> Color? {
    guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    value = value.replacingOccurrences(of: "#", with: "")
    guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
    return Color(red: Double((rgb >> 16) & 0xff) / 255,
                 green: Double((rgb >> 8) & 0xff) / 255,
                 blue: Double(rgb & 0xff) / 255)
}

extension SportsGame {
    /// The first network only: a tile has room for one, and the first is
    /// the one the game is on.
    var leadNetwork: String? {
        let first = broadcast.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first, !first.isEmpty else { return nil }
        return first
    }

    /// A short name for each side, for a line that has to fit beside a time
    /// and two logos: "Chiefs at Bills". College teams go by their
    /// abbreviation, which is what tells two schools apart -- a nickname
    /// such as Tigers does not.
    var shortMatchup: String {
        if isEvent { return eventName ?? "" }
        if league == .ncaaf {
            return "\(Self.code(awayAbbreviation, awayTeam)) at \(Self.code(homeAbbreviation, homeTeam))"
        }
        return "\(Self.nickname(awayTeam)) at \(Self.nickname(homeTeam))"
    }

    static func code(_ abbreviation: String, _ name: String) -> String {
        let trimmed = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(name.prefix(3)).uppercased() : trimmed
    }

    /// The part of a team's name that it goes by: the last word, or the last
    /// two where the nickname is two words long.
    static func nickname(_ name: String) -> String {
        let twoWord = ["Red Sox", "White Sox", "Blue Jays", "Maple Leafs", "Golden Knights",
                       "Blue Jackets", "Red Wings", "Trail Blazers"]
        if let match = twoWord.first(where: { name.hasSuffix($0) }) { return match }
        return name.split(separator: " ").last.map(String.init) ?? name
    }
}

/// One game on now: both sides and their scores, the clock, the network,
/// tinted in the two teams' colours.
struct MobileScoreTile: View {
    let game: SportsGame
    /// The game in the preview above, marked so the eye finds it again.
    var isWatching = false
    var isFollowed = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                MobileLiveStatusPill(text: game.status.isEmpty ? "Live" : game.status)
                Spacer(minLength: 2)
                if isFollowed {
                    Image(systemName: "star.fill").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.96, green: 0.77, blue: 0.09))
                        .accessibilityHidden(true)
                }
                if let network = game.leadNetwork {
                    Text(network.uppercased()).font(.inter(10, .bold))
                        .foregroundStyle(LineupStyle.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if game.isEvent {
                HStack(spacing: 9) {
                    MobileLeagueLogo(league: game.league, size: 28)
                    Text(game.eventName ?? "").font(.inter(14, .bold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 6) {
                    side(logo: game.awayLogo, code: SportsGame.code(game.awayAbbreviation, game.awayTeam),
                         score: game.awayScore, leads: leads(game.awayScore, over: game.homeScore))
                    side(logo: game.homeLogo, code: SportsGame.code(game.homeAbbreviation, game.homeTeam),
                         score: game.homeScore, leads: leads(game.homeScore, over: game.awayScore))
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 10)
        .frame(height: 124)
        .background { MobileTeamWash(away: game.awayColor, home: game.homeColor) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(isWatching ? LineupStyle.text.opacity(0.85) : LineupStyle.line,
                                    lineWidth: isWatching ? 1.5 : 1))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// Level scores both read as leading: nobody is behind yet.
    private func leads(_ score: String, over other: String) -> Bool {
        guard let mine = Int(score), let theirs = Int(other) else { return true }
        return mine >= theirs
    }

    private func side(logo: String, code: String, score: String, leads: Bool) -> some View {
        HStack(spacing: 8) {
            TeamBadge(url: logo, fallback: code, size: 26)
            Text(code).font(.inter(15, .heavy)).lineLimit(1)
            Spacer(minLength: 4)
            Text(score).font(.interDigits(22, .heavy)).lineLimit(1)
        }
        .foregroundStyle(LineupStyle.text.opacity(leads ? 1 : 0.55))
    }

    private var spoken: String {
        let clock = game.status.isEmpty ? "Live" : game.status
        let network = game.leadNetwork.map { ", on \($0)" } ?? ""
        if game.isEvent { return "\(game.eventName ?? ""), \(clock)\(network)" }
        return "\(game.awayTeam) \(game.awayScore), \(game.homeTeam) \(game.homeScore), \(clock)\(network)"
    }
}

/// The two teams' colours, washed in from opposite corners over the card.
struct MobileTeamWash: View {
    let away: String?
    let home: String?
    var strength: Double = 0.42

    var body: some View {
        ZStack {
            LineupStyle.surface
            if let away = mobileTeamColor(away) {
                RadialGradient(colors: [away.opacity(strength), away.opacity(0)],
                               center: .topLeading, startRadius: 0, endRadius: 170)
            }
            if let home = mobileTeamColor(home) {
                RadialGradient(colors: [home.opacity(strength), home.opacity(0)],
                               center: .bottomTrailing, startRadius: 0, endRadius: 170)
            }
        }
    }
}

/// The game clock on a dark pill, with the live light.
struct MobileLiveStatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            MobileLiveDot()
            Text(text).font(.inter(10.5, .heavy)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(height: 22)
        .background(Color.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(LineupStyle.text)
    }
}

/// One game still to come: when, who, where to watch, and a bell.
struct MobileUpcomingRow: View {
    @EnvironmentObject private var reminders: GameReminders
    let game: SportsGame
    /// The time alone under a heading that names the day; the day too where
    /// there is none.
    var showsDay = false

    var body: some View {
        HStack(spacing: 11) {
            Text(showsDay ? game.startLabel : game.start.formatted(.dateTime.hour().minute()))
                .font(.interDigits(showsDay ? 12 : 14, .heavy))
                .lineLimit(2).minimumScaleFactor(0.85)
                .frame(width: 62, alignment: .leading)
            logos
            VStack(alignment: .leading, spacing: 1) {
                Text(game.shortMatchup).font(.inter(14, .bold)).lineLimit(1)
                Text([game.league.shortName, game.leadNetwork].compactMap { $0 }.joined(separator: " · "))
                    .font(.inter(11.5, .medium)).foregroundStyle(LineupStyle.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            bell
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var logos: some View {
        if game.isEvent {
            MobileLeagueLogo(league: game.league, size: 26).frame(width: 45)
        } else {
            HStack(spacing: -7) {
                TeamBadge(url: game.awayLogo, fallback: SportsGame.code(game.awayAbbreviation, game.awayTeam), size: 26)
                TeamBadge(url: game.homeLogo, fallback: SportsGame.code(game.homeAbbreviation, game.homeTeam), size: 26)
            }
            .accessibilityHidden(true)
        }
    }

    /// Setting a reminder from the row itself, rather than opening the game
    /// to be told it has not started and offered one there.
    private var bell: some View {
        let on = reminders.reminds(game)
        return Button { reminders.toggleGame(game) } label: {
            Image(systemName: on ? "bell.fill" : "bell")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? LineupStyle.background : LineupStyle.text)
                .frame(width: 34, height: 34)
                .background { if on { Circle().fill(LineupStyle.text) } }
                .lineupGlassControl(Circle(), fallback: on ? Color.clear : LineupStyle.raised)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Reminder set for \(game.shortMatchup)" : "Remind me about \(game.shortMatchup)")
    }
}

/// Under the preview: the score, the clock and the network on one line, and
/// a star for following either side.
struct MobileNowPlayingStrip: View {
    @EnvironmentObject private var library: SportsLibrary
    let game: SportsGame

    var body: some View {
        HStack(spacing: 10) {
            if game.isEvent {
                MobileLeagueLogo(league: game.league, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.eventName ?? "").font(.inter(14, .bold)).lineLimit(1)
                    clock
                }
                Spacer(minLength: 4)
            } else {
                TeamBadge(url: game.awayLogo, fallback: SportsGame.code(game.awayAbbreviation, game.awayTeam), size: 30)
                if game.isLive { score(game.awayScore, leads: leads(game.awayScore, game.homeScore)) }
                VStack(spacing: 1) {
                    if game.isLive { clock } else {
                        Text(game.startLabel).font(.interDigits(12, .heavy))
                    }
                    if let network = game.leadNetwork {
                        Text(network.uppercased()).font(.inter(10, .semibold)).foregroundStyle(LineupStyle.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                if game.isLive { score(game.homeScore, leads: leads(game.homeScore, game.awayScore)) }
                TeamBadge(url: game.homeLogo, fallback: SportsGame.code(game.homeAbbreviation, game.homeTeam), size: 30)
            }
            followMenu
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 58)
        .background { MobileTeamWash(away: game.awayColor, home: game.homeColor, strength: 0.5) }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(LineupStyle.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var clock: some View {
        HStack(spacing: 5) {
            MobileLiveDot()
            Text(game.status.isEmpty ? "Live" : game.status).font(.inter(11, .heavy)).lineLimit(1)
        }
        .foregroundStyle(LineupStyle.liveStatus)
    }

    private func leads(_ score: String, _ other: String) -> Bool {
        guard let mine = Int(score), let theirs = Int(other) else { return true }
        return mine >= theirs
    }

    private func score(_ value: String, leads: Bool) -> some View {
        Text(value).font(.interDigits(22, .heavy))
            .foregroundStyle(LineupStyle.text.opacity(leads ? 1 : 0.6))
    }

    @ViewBuilder
    private var followMenu: some View {
        let sides = library.followableSides(of: game)
        if !sides.isEmpty {
            let following = sides.contains { library.isFollowing($0.key) }
            Menu {
                ForEach(sides) { side in
                    let on = library.isFollowing(side.key)
                    Button(on ? "Remove \(side.name) from My Teams" : "Add \(side.name) to My Teams",
                           systemImage: on ? "star.slash" : "star") {
                        library.toggleFollow(side)
                    }
                }
            } label: {
                Image(systemName: following ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.77, blue: 0.09))
                    .frame(width: 36, height: 36)
                    .lineupGlassControl(Circle(), fallback: LineupStyle.raised)
            }
            .accessibilityLabel("Follow a team")
        }
    }
}
