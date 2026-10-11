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

    /// "Number 5 Georgia" for a ranked college team, to be read aloud.
    static func spokenName(_ name: String, rank: Int?) -> String {
        rank.map { "Number \($0) \(name)" } ?? name
    }

    /// The whole card, to be read aloud: who, the score or the start, and
    /// where it is on.
    var spokenScoreline: String {
        let network = leadNetwork.map { ", on \($0)" } ?? ""
        let when = isLive ? (status.isEmpty ? "Live" : status) : startLabel
        if isEvent { return "\(eventName ?? ""), \(when)\(network)" }
        let away = Self.spokenName(awayTeam, rank: awayRank)
        let home = Self.spokenName(homeTeam, rank: homeRank)
        guard isLive else { return "\(away) at \(home), \(when)\(network)" }
        return "\(away) \(awayScore), \(home) \(homeScore), \(when)\(network)"
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

/// A team's name with its Top 25 place raised after it, the way ESPN prints
/// a ranked college team. Unranked, it is the name alone.
func mobileRankedName(_ name: String, rank: Int?, size: CGFloat) -> Text {
    guard let rank else { return Text(verbatim: name) }
    let mark = Text(verbatim: "\(rank)")
        .font(.interDigits((size * 0.64).rounded(), .heavy))
        .baselineOffset((size * 0.38).rounded())
    return Text("\(Text(verbatim: name))\u{200A}\(mark)")
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
                    .layoutPriority(1)
                Spacer(minLength: 2)
                if isFollowed {
                    Image(systemName: "star.fill").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.96, green: 0.77, blue: 0.09))
                        .accessibilityHidden(true)
                }
                if let network = game.leadNetwork {
                    Text(network.uppercased()).font(.inter(10, .bold))
                        .foregroundStyle(LineupStyle.secondary).lineLimit(1).minimumScaleFactor(0.75)
                }
                // An event already leads with its league's mark below.
                if !game.isEvent {
                    MobileLeagueLogo(league: game.league, size: 20)
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
                         rank: game.awayRank, score: game.awayScore, leads: leads(game.awayScore, over: game.homeScore))
                    side(logo: game.homeLogo, code: SportsGame.code(game.homeAbbreviation, game.homeTeam),
                         rank: game.homeRank, score: game.homeScore, leads: leads(game.homeScore, over: game.awayScore))
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
        .accessibilityLabel(game.spokenScoreline)
    }

    /// Level scores both read as leading: nobody is behind yet.
    private func leads(_ score: String, over other: String) -> Bool {
        guard let mine = Int(score), let theirs = Int(other) else { return true }
        return mine >= theirs
    }

    private func side(logo: String, code: String, rank: Int?, score: String, leads: Bool) -> some View {
        HStack(spacing: 8) {
            TeamBadge(url: logo, fallback: code, size: 26)
            mobileRankedName(code, rank: rank, size: 15).font(.inter(15, .heavy)).lineLimit(1)
            Spacer(minLength: 4)
            Text(score).font(.interDigits(22, .heavy)).lineLimit(1)
        }
        .foregroundStyle(LineupStyle.text.opacity(leads ? 1 : 0.55))
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
            VStack(alignment: .leading, spacing: 2) {
                matchup.font(.inter(14, .bold)).lineLimit(1)
                HStack(spacing: 5) {
                    // An event's mark is already in the logo column.
                    if !game.isEvent {
                        MobileLeagueLogo(league: game.league, size: 15)
                    }
                    Text(game.leadNetwork ?? (game.isEvent ? game.league.shortName : ""))
                        .font(.inter(11.5, .medium)).foregroundStyle(LineupStyle.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            bell
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    /// "UGA⁵ at ALA³" for ranked college teams; the plain matchup otherwise.
    private var matchup: Text {
        guard game.league == .ncaaf, !game.isEvent else { return Text(verbatim: game.shortMatchup) }
        let away = mobileRankedName(SportsGame.code(game.awayAbbreviation, game.awayTeam), rank: game.awayRank, size: 14)
        let home = mobileRankedName(SportsGame.code(game.homeAbbreviation, game.homeTeam), rank: game.homeRank, size: 14)
        return Text("\(away) at \(home)")
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

/// Under the preview, a scoreboard for everything on now: the game being
/// watched first, then every other live game in every league, a new one
/// every three seconds. Tapping one plays it in the preview.
struct MobileLiveScoreboard: View {
    let watching: SportsGame
    /// Everything live, in the Live tab's own order. The watched game is
    /// taken out and put first.
    let live: [SportsGame]
    let onWatch: (SportsGame) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var shownID: String?

    static let interval: Duration = .seconds(3)

    var body: some View {
        let games = [watching] + live.filter { $0.id != watching.id }
        let ids = games.map(\.id)
        let shown = games.first { $0.id == shownID } ?? watching
        // A scoreboard that moves under VoiceOver's cursor reads as noise,
        // so with VoiceOver it stays on the game being watched.
        let rotates = ids.count > 1 && !voiceOver && scenePhase == .active
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button {
            if shown.id != watching.id { onWatch(shown) }
        } label: {
            ZStack {
                MobileNowPlayingStrip(game: shown)
                    .id(shown.id)
                    .transition(reduceMotion ? .opacity : .push(from: .bottom))
            }
            .frame(maxWidth: .infinity)
            .frame(height: MobileNowPlayingStrip.height)
            .background(LineupStyle.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(MobileCardButtonStyle())
        .accessibilityHint(shown.id == watching.id ? "" : "Plays this game in the preview")
        // Restarted whenever the games on now, or whether to turn at all,
        // change. The closure holds this render's list, never a stale one.
        .task(id: "\(rotates)|" + ids.joined(separator: ",")) {
            guard rotates else {
                if voiceOver { shownID = nil }
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                let index = ids.firstIndex(of: shownID ?? ids[0]) ?? 0
                withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.5)) {
                    shownID = ids[(index + 1) % ids.count]
                }
            }
        }
        // A newly opened game starts the board again from itself.
        .onChange(of: watching.id) { shownID = nil }
    }
}

/// One game on the scoreboard: the score, the clock and the network on one
/// line, over the two teams' colours.
struct MobileNowPlayingStrip: View {
    let game: SportsGame

    static let height: CGFloat = 58

    var body: some View {
        HStack(spacing: 10) {
            if game.isEvent {
                MobileLeagueLogo(league: game.league, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.eventName ?? "").font(.inter(14, .bold)).lineLimit(1)
                    if game.isLive { clock } else {
                        Text(game.startLabel).font(.interDigits(12, .heavy))
                    }
                }
                Spacer(minLength: 4)
            } else {
                badge(logo: game.awayLogo, code: SportsGame.code(game.awayAbbreviation, game.awayTeam), rank: game.awayRank)
                if game.isLive { score(game.awayScore, leads: leads(game.awayScore, game.homeScore)) }
                VStack(spacing: 1) {
                    if game.isLive { clock } else {
                        Text(game.startLabel).font(.interDigits(12, .heavy))
                    }
                    HStack(spacing: 4) {
                        MobileLeagueLogo(league: game.league, size: 13)
                        if let network = game.leadNetwork {
                            Text(network.uppercased()).font(.inter(10, .semibold)).foregroundStyle(LineupStyle.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if game.isLive { score(game.homeScore, leads: leads(game.homeScore, game.awayScore)) }
                badge(logo: game.homeLogo, code: SportsGame.code(game.homeAbbreviation, game.homeTeam), rank: game.homeRank)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background { MobileTeamWash(away: game.awayColor, home: game.homeColor, strength: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.spokenScoreline)
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

    /// The strip has logos rather than names, so a Top 25 place is raised
    /// after the logo instead.
    private func badge(logo: String, code: String, rank: Int?) -> some View {
        HStack(alignment: .top, spacing: 1) {
            TeamBadge(url: logo, fallback: code, size: 30)
            if let rank {
                Text(verbatim: "\(rank)").font(.interDigits(10, .heavy))
                    .foregroundStyle(LineupStyle.text)
            }
        }
    }

    private func score(_ value: String, leads: Bool) -> some View {
        Text(value).font(.interDigits(22, .heavy))
            .foregroundStyle(LineupStyle.text.opacity(leads ? 1 : 0.6))
    }
}
