import SwiftUI

// The Live tab's score bar: the strip under a game being previewed, turning
// through everything on now.

extension SportsGame {
    /// The first network only: the score bar has room for one, and the
    /// first is the one the game is on.
    var leadNetwork: String? {
        let first = broadcast.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first, !first.isEmpty else { return nil }
        return first
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
        if isEvent { return "\(matchupLine), \(when)\(network)" }
        let away = Self.spokenName(awayTeam, rank: awayRank)
        let home = Self.spokenName(homeTeam, rank: homeRank)
        guard isLive else { return "\(away) \(sidesWord == "vs" ? "versus" : "at") \(home), \(when)\(network)" }
        if league.isTennis {
            return "\(away) versus \(home), sets \(awayScore) to \(homeScore), \(when)\(network)"
        }
        return "\(away) \(awayScore), \(home) \(homeScore), \(when)\(network)"
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
    /// The place on the board's roll: a game's index, or one past the last
    /// while the first game's copy rolls into view.
    @State private var position = 0

    /// How long a game rests on the board before the next rolls up.
    static let interval: Duration = .seconds(4)
    /// The roll from one game to the next: slow to start, long and soft to
    /// land, so no part of it reads as a jump.
    private static let roll = Animation.timingCurve(0.42, 0, 0.18, 1, duration: 1.15)
    /// The roll's length and a little over, before the loop starts over.
    private static let rollTime: Duration = .milliseconds(1_250)

    var body: some View {
        let games = [watching] + live.filter { $0.id != watching.id }
        let ids = games.map(\.id)
        let index = position % max(games.count, 1)
        let shown = games[min(index, games.count - 1)]
        // A scoreboard that moves under VoiceOver's cursor reads as noise,
        // so with VoiceOver it stays on the game being watched.
        let rotates = ids.count > 1 && !voiceOver && scenePhase == .active
        // A panel's own fill and corners; the strip says itself whether the
        // game is on.
        let shape = RoundedRectangle(cornerRadius: LineupStyle.compactRadius, style: .continuous)
        // Every game stays on the board, one above the next, and the board
        // rolls up a game at a time: logos, scores and clocks are already
        // there when they come into view, rather than each game being built
        // afresh mid-slide and its logos popping in after. The first game is
        // on the end again, so the roll from the last game to the first
        // carries on upward, then quietly starts over.
        let looped = games.count > 1 ? games + [games[0]] : games
        // Plain values for the fade below, which is worked out off the main
        // actor while the board moves.
        let stripHeight = MobileNowPlayingStrip.height
        let board = Self.board
        Button {
            if shown.id != watching.id { onWatch(shown) }
        } label: {
            Group {
                if reduceMotion {
                    // Under Reduce Motion the games trade places where they
                    // stand.
                    ZStack {
                        MobileNowPlayingStrip(game: shown)
                            .id(shown.id)
                            .transition(.opacity)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(looped.enumerated()), id: \.offset) { offset, game in
                            MobileNowPlayingStrip(game: game)
                                .accessibilityHidden(offset != position)
                                // The game leaving fades and softens as it
                                // goes, and the one arriving sharpens as it
                                // comes, so the two cross rather than one
                                // shoving the other out.
                                .visualEffect { content, proxy in
                                    let middle = proxy.frame(in: .named(board)).midY
                                    let away = min(1, abs(middle - stripHeight / 2) / stripHeight)
                                    return content
                                        .opacity(1 - away * 0.95)
                                        .blur(radius: away * 4)
                                        .scaleEffect(1 - away * 0.04)
                                }
                        }
                    }
                    .offset(y: -CGFloat(position) * MobileNowPlayingStrip.height)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: MobileNowPlayingStrip.height, alignment: .top)
            .coordinateSpace(name: board)
            .background(LineupPanelStyle.fill)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(MobileCardButtonStyle())
        .accessibilityHint(shown.id == watching.id ? "" : "Plays this game in the preview")
        // Restarted whenever the games on now, or whether to turn at all,
        // change. The closure holds this render's list, never a stale one.
        .task(id: "\(rotates)|" + ids.joined(separator: ",")) {
            // A game that ended or began moves the board back to the one
            // being watched rather than onto whatever now sits at its place.
            settle(at: 0)
            guard rotates else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.35) : Self.roll) {
                    position += 1
                }
                // Past the last game, the first game's copy is in view: once
                // it has settled, swap it for the real first game unseen.
                if position >= games.count {
                    try? await Task.sleep(for: Self.rollTime)
                    guard !Task.isCancelled else { return }
                    settle(at: 0)
                }
            }
        }
        // A newly opened game starts the board again from itself.
        .onChange(of: watching.id) { settle(at: 0) }
    }

    private static let board = "MobileLiveScoreboard.board"

    /// Moves the board without a roll.
    private func settle(at place: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position = place }
    }
}

/// One game on the scoreboard: the score, the clock and the network on one
/// line.
struct MobileNowPlayingStrip: View {
    let game: SportsGame

    static let height: CGFloat = 58

    var body: some View {
        HStack(spacing: 10) {
            if game.isEvent {
                MobileLeagueLogo(league: game.league, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.matchupLine).font(.inter(14, .bold)).lineLimit(1)
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
                        SportsMark(league: game.league, competition: game.competition, size: 16)
                        if let network = game.leadNetwork {
                            Text(network.uppercased()).font(.inter(10, .semibold)).foregroundStyle(LineupStyle.secondary.opacity(0.68))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if game.isLive { score(game.homeScore, leads: leads(game.homeScore, game.awayScore)) }
                badge(logo: game.homeLogo, code: SportsGame.code(game.homeAbbreviation, game.homeTeam), rank: game.homeRank)
            }
        }
        .foregroundStyle(LineupStyle.text.opacity(0.74))
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
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
            TeamBadge(url: logo, fallback: code, size: 30, tight: true)
            if let rank {
                Text(verbatim: "\(rank)").font(.interDigits(10, .heavy))
                    .foregroundStyle(LineupStyle.text.opacity(0.76))
            }
        }
    }

    private func score(_ value: String, leads: Bool) -> some View {
        Text(value).font(.interDigits(22, .heavy))
            .foregroundStyle(leads ? LineupStyle.text.opacity(0.76)
                                   : LineupStyle.secondary.opacity(0.72))
    }
}

/// Late-game excitement callout derived from the existing `GameAlertRules`.
enum MobileGameCrunchBadge: Equatable {
    case overtime(String)
    case close

    var label: String {
        switch self {
        case .overtime(let text): return text
        case .close: return "CLOSE"
        }
    }

    var tint: Color {
        switch self {
        case .overtime: return Color(red: 1.0, green: 0.27, blue: 0.27)
        case .close: return Color(red: 1.0, green: 0.68, blue: 0.14)
        }
    }

    static func badge(for game: SportsGame) -> Self? {
        if GameAlertRules.isOvertime(game) {
            if game.league == .soccer { return .overtime("ET") }
            if game.league == .mlb { return .overtime("EXTRAS") }
            return .overtime("OT")
        }
        if GameAlertRules.isCloseLate(game) {
            return .close
        }
        return nil
    }
}

/// Picks the most compelling live game for the Sports tab's hero card:
/// a followed team in crunch time first, then OT / close late games, then
/// followed live teams, then the tightest score margin on the board.
enum MobileFeaturedGamePicker {
    static func pick(from live: [SportsGame], isFollowing: (SportsGame) -> Bool) -> SportsGame? {
        guard !live.isEmpty else { return nil }
        return live.max { lhs, rhs in
            rank(lhs, followed: isFollowing(lhs)) < rank(rhs, followed: isFollowing(rhs))
        }
    }

    private static func rank(_ game: SportsGame, followed: Bool) -> (Int, Int, Int, Int, Int) {
        let ot = GameAlertRules.isOvertime(game) ? 1 : 0
        let close = GameAlertRules.isCloseLate(game) ? 1 : 0
        let myTeam = followed ? 1 : 0
        let margin = GameAlertRules.margin(of: game)
        let hasScore = (!game.isEvent && margin != nil) ? 1 : 0
        let closeness = margin.map { -$0 } ?? -999
        let tier: Int
        if myTeam == 1 && (ot == 1 || close == 1) { tier = 6 }
        else if ot == 1 { tier = 5 }
        else if close == 1 { tier = 4 }
        else if myTeam == 1 { tier = 3 }
        else if hasScore == 1 { tier = 2 }
        else { tier = 1 }
        let rankedBoost = (game.awayRank != nil ? 1 : 0) + (game.homeRank != nil ? 1 : 0)
        return (tier, myTeam, closeness, rankedBoost, game.isEvent ? 0 : 1)
    }
}

/// Spotlight hero card at the top of the Sports tab when a game is live and
/// the inline preview player is closed.
struct MobileFeaturedGameHero: View {
    let game: SportsGame
    var awayFollowed = false
    var homeFollowed = false

    private var awayValue: Int? { Int(game.awayScore) }
    private var homeValue: Int? { Int(game.homeScore) }
    private var awayLeads: Bool {
        guard let away = awayValue, let home = homeValue else { return true }
        return away >= home
    }
    private var homeLeads: Bool {
        guard let away = awayValue, let home = homeValue else { return true }
        return home >= away
    }
    private var crunchBadge: MobileGameCrunchBadge? { MobileGameCrunchBadge.badge(for: game) }

    var body: some View {
        let awayColor = MobileTeamColor.readable(game.awayColor) ?? LineupStyle.leagueColor(game.league)
        let homeColor = MobileTeamColor.readable(game.homeColor) ?? awayColor
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        VStack(spacing: 14) {
            HStack(spacing: 7) {
                SportsMark(league: game.league, competition: game.competition, size: 18)
                Text((game.competition?.name ?? game.league.shortName).uppercased())
                    .font(.inter(11, .heavy)).tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.76))
                    .lineLimit(1)
                if let crunchBadge {
                    Text(crunchBadge.label)
                        .font(.inter(9.5, .heavy)).tracking(0.6)
                        .foregroundStyle(crunchBadge.tint)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(crunchBadge.tint.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(crunchBadge.tint.opacity(0.45), lineWidth: 0.8))
                } else if awayFollowed || homeFollowed {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 8.5, weight: .bold))
                        Text("MY TEAM").font(.inter(9.5, .heavy)).tracking(0.5)
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.25))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(red: 1.0, green: 0.80, blue: 0.25).opacity(0.16), in: Capsule())
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    MobileLiveDot()
                    Text(game.status.isEmpty ? "Live" : game.status)
                        .font(.inter(11, .heavy))
                        .lineLimit(1)
                }
                .foregroundStyle(LineupStyle.liveStatus)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.black.opacity(0.38), in: Capsule())
                .overlay(Capsule().strokeBorder(LineupStyle.liveStatus.opacity(0.32), lineWidth: 0.8))
            }

            if game.isEvent {
                HStack(spacing: 14) {
                    MobileLeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.eventName ?? game.league.shortName)
                            .font(.inter(18, .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        if let session = game.race?.title {
                            Text(session)
                                .font(.inter(13, .semibold))
                                .foregroundStyle(LineupStyle.highlight)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    heroSide(name: game.awayTeam, logo: game.awayLogo, rank: game.awayRank,
                             record: game.awayRecord, leads: awayLeads, followed: awayFollowed)
                    VStack(spacing: 4) {
                        if let sets = game.tennis {
                            TennisSetColumns(score: sets, isAway: true, size: 17)
                            TennisSetColumns(score: sets, isAway: false, size: 17)
                        } else {
                            HStack(spacing: 8) {
                                Text(game.awayScore.isEmpty ? "0" : game.awayScore)
                                    .font(.interDigits(30, .black))
                                    .foregroundStyle(awayLeads ? Color.white : Color.white.opacity(0.46))
                                Text("–")
                                    .font(.inter(18, .bold))
                                    .foregroundStyle(Color.white.opacity(0.28))
                                Text(game.homeScore.isEmpty ? "0" : game.homeScore)
                                    .font(.interDigits(30, .black))
                                    .foregroundStyle(homeLeads ? Color.white : Color.white.opacity(0.46))
                            }
                            .minimumScaleFactor(0.75)
                            .lineLimit(1)
                        }
                        if let detail = game.soccer?.detail {
                            Text(detail)
                                .font(.inter(10, .semibold))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    heroSide(name: game.homeTeam, logo: game.homeLogo, rank: game.homeRank,
                             record: game.homeRecord, leads: homeLeads, followed: homeFollowed)
                }
                .padding(.vertical, 2)
            }

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            HStack(spacing: 8) {
                if let network = game.leadNetwork {
                    Text(network.uppercased())
                        .font(.inter(10, .heavy)).tracking(0.6)
                        .foregroundStyle(Color.white.opacity(0.86))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.11), in: Capsule())
                        .lineLimit(1)
                }
                if let place = game.placeLine {
                    Text(place)
                        .font(.inter(11, .medium))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                    Text("Watch Live").font(.inter(12, .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.white.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background {
            ZStack {
                shape.fill(Color(red: 0.075, green: 0.080, blue: 0.098))
                shape.fill(
                    LinearGradient(colors: [awayColor.opacity(0.32), Color.clear, homeColor.opacity(0.32)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.white.opacity(0.08), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 56)
                    Spacer(minLength: 0)
                }
            }
            .clipShape(shape)
        }
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured live game. \(game.spokenScoreline)")
    }

    private func heroSide(name: String, logo: String, rank: Int?, record: String?,
                          leads: Bool, followed: Bool) -> some View {
        VStack(spacing: 5) {
            TeamBadge(url: logo, fallback: String(name.prefix(3)).uppercased(), size: 44, tight: true)
            HStack(spacing: 3) {
                mobileRankedName(name, rank: rank, size: 13)
                    .font(.inter(13, leads ? .bold : .semibold))
                    .foregroundStyle(leads ? Color.white : Color.white.opacity(0.62))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                if followed {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.25))
                }
            }
            if let record = record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty {
                Text(record)
                    .font(.interDigits(10.5, .medium))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
