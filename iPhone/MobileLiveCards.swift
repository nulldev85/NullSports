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
    @State private var shownID: String?

    static let interval: Duration = .seconds(3)

    var body: some View {
        let games = [watching] + live.filter { $0.id != watching.id }
        let ids = games.map(\.id)
        let shown = games.first { $0.id == shownID } ?? watching
        // A scoreboard that moves under VoiceOver's cursor reads as noise,
        // so with VoiceOver it stays on the game being watched.
        let rotates = ids.count > 1 && !voiceOver && scenePhase == .active
        // Coloured as the Guide colours a programme: grey, a step lighter and
        // edged in a faint red while it is on.
        let shape = RoundedRectangle(cornerRadius: LineupStyle.compactRadius, style: .continuous)
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
            .background(shown.isLive ? LineupStyle.focused : LineupStyle.raised)
            .clipShape(shape)
            .overlay(shape.strokeBorder(shown.isLive ? LineupStyle.liveDot.opacity(0.34) : LineupStyle.line,
                                        lineWidth: shown.isLive ? 1 : 0.5))
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
/// line.
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
                    .foregroundStyle(LineupStyle.text)
            }
        }
    }

    private func score(_ value: String, leads: Bool) -> some View {
        Text(value).font(.interDigits(22, .heavy))
            .foregroundStyle(leads ? LineupStyle.text : LineupStyle.secondary)
    }
}
