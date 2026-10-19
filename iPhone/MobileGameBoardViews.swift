import SwiftUI

// The live panel's own views for the sports whose feed is a scoreboard: a
// tennis match and the courts around it, a fight card, a race's order.
// Each draws its board as far as the picture has got, and nothing further.

/// A tennis match as a scoreboard draws it: a line for each player, the
/// sets across, the server marked.
struct MobileTennisMatchBoard: View {
    let match: GameStatsTennisMatch
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            player(.away)
            player(.home)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(match.away.name) against \(match.home.name), \(match.status)")
    }

    private func player(_ side: GameStatsSide) -> some View {
        let who = side == .away ? match.away : match.home
        let seed = side == .away ? match.awaySeed : match.homeSeed
        let lost = match.winner.map { $0 != side } ?? false
        return HStack(spacing: 10) {
            TeamBadge(url: who.logo ?? "", fallback: String(who.abbreviation.prefix(3)).uppercased(),
                      size: compact ? 22 : 28, tight: true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(compact ? who.abbreviation : who.name)
                    .font(.inter(compact ? 14 : 16, lost ? .medium : .semibold))
                    .foregroundStyle(lost ? LineupPanelStyle.quiet : LineupStyle.text)
                    .lineLimit(1)
                if let seed {
                    Text(verbatim: "\(seed)").font(.interDigits(10, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                }
            }
            if match.serving == side {
                Circle().fill(LineupStyle.highlight).frame(width: 7, height: 7)
            }
            Spacer(minLength: 6)
            if !match.sets.isEmpty {
                TennisSetColumns(score: match.score, isAway: side == .away, size: compact ? 16 : 20,
                                 primary: LineupStyle.text, secondary: LineupPanelStyle.quiet)
            }
        }
    }
}

/// The top of a tennis panel: the match on screen, or the tournament while
/// none is picked.
struct MobileTennisHeader: View {
    let draw: GameStatsTennisBoard
    let match: GameStatsTennisMatch?
    /// The picture has yet to reach the draw: who is playing, and nothing
    /// of how it stands.
    var catchingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(caption).font(.inter(11, .heavy)).tracking(0.6)
                    .foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
                Spacer(minLength: 6)
                if let match {
                    Text(match.status).font(.interDigits(12, .heavy)).lineLimit(1)
                        .foregroundStyle(match.state == "in" ? LineupStyle.liveStatus : LineupPanelStyle.quiet)
                }
            }
            if let match {
                MobileTennisMatchBoard(match: match)
            } else {
                Text(draw.tournament).font(.inter(18, .bold)).lineLimit(2)
                if catchingUp {
                    Text("Held until your stream gets here").font(.inter(13, .semibold))
                        .foregroundStyle(LineupPanelStyle.quiet)
                } else {
                    Text(draw.live.isEmpty ? "No match on court right now"
                         : (draw.live.count == 1 ? "1 match on court" : "\(draw.live.count) matches on court"))
                        .font(.inter(13, .semibold))
                        .foregroundStyle(draw.live.isEmpty ? LineupPanelStyle.quiet : LineupStyle.liveStatus)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var caption: String {
        guard let match else { return "TENNIS" }
        return [match.round, match.court].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ").uppercased()
    }
}

/// Every match of the day in the draw: on court, up next, and done. The
/// other courts as ESPN has them now; the match on screen as the picture
/// has it -- see `GameStatsTennisBoard.courts`.
struct MobileTennisCourts: View {
    let courts: [GameStatsCourt]
    /// The match on the viewer's screen, where one is known.
    let onScreen: String?
    /// Picks the match on screen. Nil on a match's own panel, where the
    /// match opened is the one on screen.
    let onPick: ((String) -> Void)?

    var body: some View {
        let matches = courts.map(\.match)
        let live = matches.filter { $0.state == "in" }
        let upcoming = matches.filter { $0.state == "pre" }
        let results = matches.filter { $0.state == "post" }.reversed()
        LazyVStack(alignment: .leading, spacing: 0) {
            if onPick != nil, onScreen == nil, live.count > 1 {
                Text("Tap the match on your screen. Its plays are the ones synced to, and the rest show live.")
                    .font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            group("ON COURT", Array(live))
            group("UP NEXT", Array(upcoming))
            group("RESULTS", Array(results))
            if matches.isEmpty {
                Text("No singles today.").font(.inter(14)).foregroundStyle(LineupPanelStyle.quiet)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ matches: [GameStatsTennisMatch]) -> some View {
        if !matches.isEmpty {
            Text(title).font(.inter(11, .heavy)).tracking(0.6).foregroundStyle(LineupPanelStyle.quiet)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
            ForEach(matches) { match in
                // Only a match on court can be the one on screen.
                if let onPick, match.state == "in" {
                    Button { onPick(match.id) } label: { row(match) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Syncs the stats to this match")
                } else {
                    row(match)
                }
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, 16)
            }
        }
    }

    private func row(_ match: GameStatsTennisMatch) -> some View {
        let picked = match.id == onScreen
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(caption(match)).font(.inter(11, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if picked {
                    Label("On your screen", systemImage: "checkmark.circle.fill")
                        .font(.inter(11, .bold)).foregroundStyle(LineupIconTile.green)
                }
            }
            MobileTennisMatchBoard(match: match, compact: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(picked ? LineupPanelStyle.well : .clear)
        .contentShape(Rectangle())
    }

    private func caption(_ match: GameStatsTennisMatch) -> String {
        var parts = [match.round, match.court ?? ""]
        if match.state == "pre", let start = match.start {
            parts.append(start.formatted(.dateTime.hour().minute()))
        }
        if match.state == "in" { parts.append(match.status) }
        return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}

/// The top of a fight night: the fight on now, else the next one, else how
/// the main event ended.
struct MobileFightHeader: View {
    let card: GameStatsFightCard

    var body: some View {
        if let bout = card.headline {
            VStack(spacing: 10) {
                Text(caption(bout)).font(.inter(11, .heavy)).tracking(0.6)
                    .foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
                HStack(alignment: .center, spacing: 10) {
                    fighter(bout, .away)
                    middle(bout).frame(minWidth: 84)
                    fighter(bout, .home)
                }
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
        }
    }

    private func caption(_ bout: GameStatsBout) -> String {
        let place: String
        if bout.state == "in" {
            place = "Fight \((card.bouts.firstIndex(of: bout) ?? 0) + 1) of \(card.bouts.count)"
        } else if bout.state == "pre" {
            place = "Up next"
        } else {
            place = bout == card.mainEvent ? "Main event" : "Final"
        }
        return [place, bout.weightClass].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ").uppercased()
    }

    private func fighter(_ bout: GameStatsBout, _ side: GameStatsSide) -> some View {
        let who = side == .away ? bout.away : bout.home
        let record = side == .away ? bout.awayRecord : bout.homeRecord
        let won = bout.winner == side
        let lost = bout.winner != nil && !won
        return VStack(spacing: 4) {
            TeamBadge(url: who.logo ?? "", fallback: String(who.abbreviation.prefix(3)).uppercased(), size: 30, tight: true)
            Text(who.name).font(.inter(14, won ? .bold : .semibold)).multilineTextAlignment(.center)
                .foregroundStyle(lost ? LineupPanelStyle.quiet : LineupStyle.text)
                .lineLimit(2).minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                if won {
                    Text("W").font(.inter(10, .heavy)).foregroundStyle(LineupStyle.onHighlight)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(LineupStyle.highlight, in: Capsule())
                }
                if let record { Text(record).font(.interDigits(11, .semibold)).foregroundStyle(LineupPanelStyle.quiet) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func middle(_ bout: GameStatsBout) -> some View {
        switch bout.state {
        case "in":
            VStack(spacing: 2) {
                Text("R\(max(bout.round, 1))").font(.interDigits(26, .bold)).foregroundStyle(LineupStyle.liveStatus)
                if let clock = bout.clock { Text(clock).font(.interDigits(13, .heavy)).foregroundStyle(LineupPanelStyle.quiet) }
            }
        case "post":
            VStack(spacing: 2) {
                Text(bout.method ?? "Final").font(.inter(15, .bold)).multilineTextAlignment(.center)
                if bout.round > 0 {
                    Text("R\(bout.round)" + (bout.clock.map { " \($0)" } ?? ""))
                        .font(.interDigits(12, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                }
            }
        default:
            VStack(spacing: 2) {
                Text("vs").font(.inter(16, .bold)).foregroundStyle(LineupPanelStyle.quiet)
                Text("\(bout.rounds) rounds").font(.inter(11, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
            }
        }
    }
}

/// Every fight on the card, the main event first.
struct MobileFightCardList: View {
    let card: GameStatsFightCard

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(card.bouts.reversed())) { bout in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(caption(bout)).font(.inter(10, .heavy)).tracking(0.6)
                            .foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
                        name(bout, .away)
                        name(bout, .home)
                    }
                    Spacer(minLength: 8)
                    outcome(bout).multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(bout.state == "in" ? LineupPanelStyle.well : .clear)
                .accessibilityElement(children: .combine)
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, 16)
            }
        }
    }

    private func caption(_ bout: GameStatsBout) -> String {
        ([bout == card.mainEvent ? "Main event" : "", bout.weightClass]).filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ").uppercased()
    }

    private func name(_ bout: GameStatsBout, _ side: GameStatsSide) -> some View {
        let who = side == .away ? bout.away : bout.home
        let won = bout.winner == side
        return HStack(spacing: 6) {
            Text(who.name).font(.inter(15, won ? .bold : .medium)).lineLimit(1)
                .foregroundStyle(bout.winner != nil && !won ? LineupPanelStyle.quiet : LineupStyle.text)
            if won {
                Text("W").font(.inter(10, .heavy)).foregroundStyle(LineupStyle.onHighlight)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(LineupStyle.highlight, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func outcome(_ bout: GameStatsBout) -> some View {
        switch bout.state {
        case "in":
            HStack(spacing: 5) {
                MobileLiveDot()
                Text("R\(max(bout.round, 1))" + (bout.clock.map { " \u{00B7} \($0)" } ?? ""))
                    .font(.interDigits(13, .heavy))
            }
            .foregroundStyle(LineupStyle.liveStatus)
        case "post":
            VStack(alignment: .trailing, spacing: 2) {
                Text(bout.method ?? "Final").font(.inter(13, .bold))
                if bout.round > 0 {
                    Text("R\(bout.round)" + (bout.clock.map { " \($0)" } ?? ""))
                        .font(.interDigits(11, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                }
            }
        default:
            Text(bout.start.map { $0.formatted(.dateTime.hour().minute()) } ?? "Later")
                .font(.interDigits(13, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
        }
    }
}

/// The top of a race panel: the session, the lap, who leads.
struct MobileRaceHeader: View {
    let race: GameStatsRaceBoard

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(race.session.uppercased()).font(.inter(11, .heavy)).tracking(0.6)
                    .foregroundStyle(LineupPanelStyle.quiet)
                Text(race.status.isEmpty ? "—" : race.status).font(.interDigits(22, .bold))
                    .foregroundStyle(race.state == "in" ? LineupStyle.liveStatus : LineupStyle.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            if let leader = race.leader {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(race.state == "post" ? (race.isRace ? "WINNER" : "FASTEST") : "LEADER")
                            .font(.inter(10, .heavy)).tracking(0.6).foregroundStyle(LineupPanelStyle.quiet)
                        Text(leader.name).font(.inter(15, .semibold)).lineLimit(1)
                    }
                    TeamBadge(url: leader.flag ?? "", fallback: "P1", size: 30, tight: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// The running order, each driver marked with how far they have moved in
/// the last half minute of what the picture has shown.
struct MobileRacePositions: View {
    let race: GameStatsRaceBoard
    let earlier: GameStatsRaceBoard?

    var body: some View {
        if race.entrants.isEmpty {
            VStack(spacing: 10) {
                LineupIconTile(symbol: "flag.checkered", size: 34, tint: LineupIconTile.gray)
                Text(race.state == "pre" ? "The order appears once the session starts." : "No order yet.")
                    .font(.inter(14)).foregroundStyle(LineupPanelStyle.quiet)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28)
        } else {
            let before = Dictionary((earlier?.entrants ?? []).map { ($0.id, $0.position) },
                                    uniquingKeysWith: { first, _ in first })
            LazyVStack(spacing: 0) {
                ForEach(race.entrants) { entrant in
                    HStack(spacing: 12) {
                        Text(verbatim: "\(entrant.position)").font(.interDigits(15, .bold))
                            .frame(width: 28, alignment: .trailing)
                        TeamBadge(url: entrant.flag ?? "", fallback: String(entrant.name.prefix(2)).uppercased(),
                                  size: 22, tight: true)
                        Text(entrant.name).font(.inter(15, entrant.position <= 3 ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let was = before[entrant.id], was != entrant.position {
                            let gained = was - entrant.position
                            Label("\(abs(gained))", systemImage: gained > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                .font(.interDigits(12, .bold))
                                .foregroundStyle(gained > 0 ? LineupIconTile.green : LineupIconTile.red)
                                .accessibilityLabel(gained > 0 ? "Up \(gained)" : "Down \(-gained)")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, 56)
                }
            }
        }
    }
}
