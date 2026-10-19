import SwiftUI

/// Live stats for the game being watched, beside or under the picture: the
/// score as far as the picture has got, its chances, and its plays, box
/// score and leaders, every one of them held until the picture shows it.
struct MobileGameStatsPanel: View {
    @ObservedObject var stats: MobileGameStats
    let game: SportsGame
    /// Beside a full-screen picture, rather than under an upright one.
    var sideways = false
    let onSync: () -> Void
    var onClose: (() -> Void)? = nil

    enum StatsSection: String, CaseIterable, Identifiable {
        case plays = "Plays", box = "Box Score", leaders = "Leaders"
        var id: String { rawValue }
    }
    @State private var section: StatsSection = .plays

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LineupIconTile(symbol: "chart.bar.fill", size: 26)
                Text("LIVE STATS").font(.inter(13, .heavy)).tracking(LineupPanelStyle.headerTracking)
                    .foregroundStyle(LineupPanelStyle.caption)
                Spacer(minLength: 8)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(LineupStyle.text)
                            .frame(width: 30, height: 30)
                            .background(LineupPanelStyle.well, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close stats")
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            if let reveal = stats.reveal {
                scoreboard(reveal)
                syncChip(reveal).padding(.horizontal, 16).padding(.top, 10)
                if let home = reveal.homeWinProbability {
                    WinProbabilityBar(reveal: reveal, home: home).padding(.horizontal, 16).padding(.top, 14)
                }
                HStack(spacing: 8) {
                    ForEach(StatsSection.allCases) { option in
                        Button { withAnimation(.easeInOut(duration: 0.16)) { section = option } } label: {
                            Text(option.rawValue).lineupChip(section == option)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                ScrollView {
                    switch section {
                    case .plays: plays(reveal)
                    case .box: box(reveal)
                    case .leaders: leaders(reveal)
                    }
                }
                .scrollIndicators(.hidden)
            } else if stats.unavailable {
                message("Stats aren't available for this game.", symbol: "chart.bar")
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(LineupStyle.text)
                    Text("Loading stats…").font(.inter(14)).foregroundStyle(LineupPanelStyle.quiet)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(LineupStyle.text)
        .background(LineupPanelStyle.fill)
    }

    // MARK: Score

    private func scoreboard(_ reveal: GameStatsReveal) -> some View {
        HStack(spacing: 10) {
            team(logo: game.awayLogo, code: SportsGame.code(reveal.away.abbreviation, game.awayTeam))
            Text("\(reveal.awayScore)").font(.interDigits(sideways ? 28 : 32, .bold))
                .foregroundStyle(reveal.awayScore >= reveal.homeScore ? LineupStyle.text : LineupPanelStyle.quiet)
            VStack(spacing: 2) {
                Text(reveal.status.isEmpty ? "—" : reveal.status)
                    .font(.interDigits(13, .heavy))
                    .foregroundStyle(reveal.state == "in" ? LineupStyle.liveStatus : LineupPanelStyle.quiet)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            Text("\(reveal.homeScore)").font(.interDigits(sideways ? 28 : 32, .bold))
                .foregroundStyle(reveal.homeScore >= reveal.awayScore ? LineupStyle.text : LineupPanelStyle.quiet)
            team(logo: game.homeLogo, code: SportsGame.code(reveal.home.abbreviation, game.homeTeam))
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reveal.away.name) \(reveal.awayScore), \(reveal.home.name) \(reveal.homeScore), \(reveal.status)")
    }

    private func team(logo: String, code: String) -> some View {
        VStack(spacing: 3) {
            TeamBadge(url: logo, fallback: code, size: sideways ? 30 : 34)
            Text(code).font(.inter(11, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
        }
    }

    /// How the stats are kept with the picture, and the way to set it.
    private func syncChip(_ reveal: GameStatsReveal) -> some View {
        Button(action: onSync) {
            HStack(spacing: 8) {
                Image(systemName: stats.calibrated ? "checkmark.circle.fill" : "timer")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(stats.calibrated ? LineupIconTile.green : LineupStyle.highlight)
                Text(syncText(reveal)).font(.inter(12, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(stats.calibrated ? "Adjust" : "Sync").font(.inter(12, .bold)).foregroundStyle(LineupStyle.highlight)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(LineupPanelStyle.well, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Matches the stats to your picture")
    }

    private func syncText(_ reveal: GameStatsReveal) -> String {
        let seconds = Int(stats.totalDelay.rounded())
        if reveal.catchingUp { return "Catching up to your stream · \(seconds)s" }
        return stats.calibrated ? "In sync with your stream · \(seconds)s behind" : "Held \(seconds)s behind · tap to sync"
    }

    // MARK: Sections

    @ViewBuilder
    private func plays(_ reveal: GameStatsReveal) -> some View {
        if reveal.plays.isEmpty {
            message(reveal.state == "pre" ? "Plays appear here once the game starts." : "No plays yet.",
                    symbol: "list.bullet")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(reveal.plays.prefix(120)) { play in
                    PlayRow(play: play, reveal: reveal, game: game)
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func box(_ reveal: GameStatsReveal) -> some View {
        if reveal.lines.isEmpty {
            message(reveal.catchingUp ? "The box score appears once your stream reaches it."
                                      : "No box score yet.", symbol: "tablecells")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text(SportsGame.code(reveal.away.abbreviation, game.awayTeam))
                    Spacer()
                    Text(SportsGame.code(reveal.home.abbreviation, game.homeTeam))
                }
                .font(.inter(12, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                .padding(.horizontal, 16).padding(.vertical, 10)
                ForEach(Array(reveal.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 8) {
                        Text(line.away).font(.interDigits(15, .semibold)).frame(width: 74, alignment: .leading)
                        Text(line.label).font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        Text(line.home).font(.interDigits(15, .semibold)).frame(width: 74, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func leaders(_ reveal: GameStatsReveal) -> some View {
        if reveal.leaders.isEmpty {
            message(reveal.catchingUp ? "Leaders appear once your stream reaches them." : "No leaders yet.",
                    symbol: "person.2")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(reveal.leaders.enumerated()), id: \.offset) { _, leader in
                    let home = leader.teamID == reveal.home.id
                    HStack(spacing: 12) {
                        TeamBadge(url: home ? game.homeLogo : game.awayLogo,
                                  fallback: home ? reveal.home.abbreviation : reveal.away.abbreviation, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leader.category.uppercased()).font(.inter(10, .heavy)).tracking(0.6)
                                .foregroundStyle(LineupPanelStyle.quiet)
                            Text(leader.athlete).font(.inter(15, .semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(leader.value).font(.interDigits(14, .semibold)).multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, 54)
                }
            }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            LineupIconTile(symbol: symbol, size: 34)
            Text(text).font(.inter(14)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One play: when it happened, what it was, and the score it made.
private struct PlayRow: View {
    let play: GameStatsPlay
    let reveal: GameStatsReveal
    let game: SportsGame

    var body: some View {
        let home = play.teamID == reveal.home.id
        let color = MobileTeamColor.readable(home ? reveal.home.color : (play.teamID == reveal.away.id ? reveal.away.color : nil))
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(color ?? LineupPanelStyle.divider).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text([play.period, play.clock].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.interDigits(11, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                    if play.scoring {
                        Text("\(SportsGame.code(reveal.away.abbreviation, game.awayTeam)) \(play.awayScore) – \(play.homeScore) \(SportsGame.code(reveal.home.abbreviation, game.homeTeam))")
                            .font(.interDigits(11, .heavy))
                            .foregroundStyle(LineupStyle.onHighlight)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(LineupStyle.highlight, in: Capsule())
                    }
                }
                Text(play.text).font(.inter(14, play.scoring ? .semibold : .regular))
                    .foregroundStyle(LineupStyle.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Who is likely to win, as of the last play the picture has shown.
private struct WinProbabilityBar: View {
    let reveal: GameStatsReveal
    let home: Double

    var body: some View {
        let away = 1 - home
        let awayColor = MobileTeamColor.readable(reveal.away.color) ?? LineupPanelStyle.quiet
        let homeColor = MobileTeamColor.readable(reveal.home.color) ?? LineupStyle.highlight
        VStack(spacing: 6) {
            HStack {
                Text("\(reveal.away.abbreviation) \(Int((away * 100).rounded()))%")
                Spacer()
                Text("WIN PROBABILITY").font(.inter(10, .heavy)).tracking(0.8).foregroundStyle(LineupPanelStyle.quiet)
                Spacer()
                Text("\(Int((home * 100).rounded()))% \(reveal.home.abbreviation)")
            }
            .font(.interDigits(12, .heavy))
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Capsule().fill(awayColor).frame(width: max(4, (proxy.size.width - 2) * away))
                    Capsule().fill(homeColor)
                }
            }
            .frame(height: 8)
            .animation(.easeInOut(duration: 0.4), value: home)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Win probability: \(reveal.away.name) \(Int((away * 100).rounded())) percent, \(reveal.home.name) \(Int((home * 100).rounded())) percent")
    }
}

/// A team's colour from its hex, lifted until it reads on the panels' grey.
enum MobileTeamColor {
    static func readable(_ hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "#", with: "")
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        var red = Double((number >> 16) & 0xff) / 255
        var green = Double((number >> 8) & 0xff) / 255
        var blue = Double(number & 0xff) / 255
        let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
        if luminance < 0.45 {
            let mix = (0.45 - luminance) / max(0.01, 1 - luminance)
            red += (1 - red) * mix; green += (1 - green) * mix; blue += (1 - blue) * mix
        }
        return Color(red: red, green: green, blue: blue)
    }
}

/// Matching the stats to the picture: the game clock as the stats have it,
/// to be lined up with the one on screen, or one tap the moment a score
/// appears.
struct MobileStatsSyncSheet: View {
    @ObservedObject var stats: MobileGameStats
    let game: SportsGame
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                LineupIconTile(symbol: "timer", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync With Your Stream").font(.inter(19, .bold))
                    Text("Every score, play and stat waits until your picture shows it.")
                        .font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 22)

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                VStack(spacing: 4) {
                    Text(stats.clockText ?? stats.reveal?.status ?? "—")
                        .font(.interDigits(44, .bold))
                        .contentTransition(.numericText())
                    if let reveal = stats.reveal {
                        Text("\(reveal.away.abbreviation) \(reveal.awayScore) – \(reveal.homeScore) \(reveal.home.abbreviation)  ·  \(reveal.status)")
                            .font(.interDigits(14, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if let last = reveal.plays.first {
                            Text(last.text).font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                                .lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18).padding(.horizontal, 16)
                .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 20).padding(.top, 18)

            Text("Match this to the game clock on your screen. If the stats are ahead of your picture, hold them back.")
                .font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
                .padding(.horizontal, 28).padding(.top, 12)

            HStack(spacing: 10) {
                nudge("−5", by: -5)
                nudge("−1", by: -1)
                VStack(spacing: 1) {
                    Text("\(Int(stats.delay.rounded()))s").font(.interDigits(22, .bold)).contentTransition(.numericText())
                    Text("HELD BACK").font(.inter(10, .heavy)).tracking(0.8).foregroundStyle(LineupPanelStyle.quiet)
                }
                .frame(minWidth: 84)
                nudge("+1", by: 1)
                nudge("+5", by: 5)
            }
            .padding(.top, 16)

            Button {
                note = stats.syncToLatestScore()
                    ? "Synced to the latest score."
                    : "No score in the last few minutes. Match the clock instead."
            } label: {
                Label("I Just Saw a Score", systemImage: "sportscourt.fill")
                    .frame(maxWidth: .infinity)
            }
            .lineupProminentButton()
            .padding(.horizontal, 20).padding(.top, 18)
            if let note {
                Text(note).font(.inter(12)).foregroundStyle(LineupPanelStyle.quiet).padding(.top, 8)
            }

            HStack {
                Button("Reset") { stats.resetDelay(); note = nil }.buttonStyle(LineupBarButtonStyle())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(LineupBarButtonStyle(prominent: true))
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
        }
        .foregroundStyle(LineupStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LineupPanelStyle.fill.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LineupPanelStyle.fill)
        // The picture stays live above the sheet, to be matched against.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .animation(.easeInOut(duration: 0.2), value: stats.delay)
    }

    private func nudge(_ title: String, by seconds: TimeInterval) -> some View {
        Button { stats.nudge(by: seconds); note = nil } label: {
            Text(title).font(.interDigits(16, .bold)).frame(width: 48, height: 40)
                .background(LineupPanelStyle.well, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds < 0 ? "Show stats \(Int(-seconds)) seconds sooner"
                                        : "Hold stats \(Int(seconds)) seconds longer")
    }
}
