import SwiftUI

/// The stats' sizes, as `GameStatsScale` has them on this platform.
private func scaled(_ points: CGFloat) -> CGFloat { GameStatsScale.size(points) }

// The live stats' rows, drawn the same on both apps: at the phone's sizes
// there, and on the television at the sizes read from across a room.

extension SportsGame {
    /// A side's short name on a scoreboard: its abbreviation, else the first
    /// three letters of its name.
    static func code(_ abbreviation: String, _ name: String) -> String {
        let trimmed = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(name.prefix(3)).uppercased() : trimmed
    }
}

/// How large the live stats are drawn: the phone's own sizes, and the
/// television's, half as large again and more.
enum GameStatsScale {
    #if os(tvOS)
    static let factor: CGFloat = 1.6
    #else
    static let factor: CGFloat = 1
    #endif

    static func size(_ points: CGFloat) -> CGFloat { (points * factor).rounded() }
}

/// One play: when it happened, what it was, and the score it made.
struct GameStatsPlayRow: View {
    let play: GameStatsPlay
    let reveal: GameStatsReveal
    let game: SportsGame

    var body: some View {
        let home = play.teamID == reveal.home.id
        let color = MobileTeamColor.readable(home ? reveal.home.color : (play.teamID == reveal.away.id ? reveal.away.color : nil))
        HStack(alignment: .top, spacing: scaled(12)) {
            RoundedRectangle(cornerRadius: scaled(2))
                .fill(color ?? (play.scoring && play.seen != nil ? LineupStyle.highlight : LineupPanelStyle.divider))
                .frame(width: scaled(3))
            VStack(alignment: .leading, spacing: scaled(4)) {
                HStack(spacing: scaled(6)) {
                    Text([play.period, play.clock].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.interDigits(scaled(11), .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                    if let badge = play.badge {
                        Text(badge)
                            .font(.interDigits(scaled(11), .heavy))
                            .foregroundStyle(play.scoring ? LineupStyle.onHighlight : LineupStyle.text)
                            .padding(.horizontal, scaled(7)).padding(.vertical, scaled(2))
                            .background(play.scoring ? LineupStyle.highlight : LineupPanelStyle.well, in: Capsule())
                    } else if play.scoring {
                        Text("\(SportsGame.code(reveal.away.abbreviation, game.awayTeam)) \(play.awayScore) – \(play.homeScore) \(SportsGame.code(reveal.home.abbreviation, game.homeTeam))")
                            .font(.interDigits(scaled(11), .heavy))
                            .foregroundStyle(LineupStyle.onHighlight)
                            .padding(.horizontal, scaled(7)).padding(.vertical, scaled(2))
                            .background(LineupStyle.highlight, in: Capsule())
                    }
                }
                Text(play.text).font(.inter(scaled(14), play.scoring ? .semibold : .regular))
                    .foregroundStyle(LineupStyle.text)
                    .fixedSize(horizontal: false, vertical: true)
                // On a board of several matches or fights, which one.
                if play.seen != nil, let context = play.drive {
                    Text(context).font(.inter(scaled(12))).foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scaled(16)).padding(.vertical, scaled(10))
        .accessibilityElement(children: .combine)
    }
}

/// Who is likely to win, as of the last play the picture has shown.
struct WinProbabilityBar: View {
    let reveal: GameStatsReveal
    let home: Double

    var body: some View {
        let away = 1 - home
        let awayColor = MobileTeamColor.readable(reveal.away.color) ?? LineupPanelStyle.quiet
        let homeColor = MobileTeamColor.readable(reveal.home.color) ?? LineupStyle.highlight
        VStack(spacing: scaled(6)) {
            HStack {
                Text("\(reveal.away.abbreviation) \(Int((away * 100).rounded()))%")
                Spacer()
                Text("WIN PROBABILITY").font(.inter(scaled(10), .heavy)).tracking(0.8).foregroundStyle(LineupPanelStyle.quiet)
                Spacer()
                Text("\(Int((home * 100).rounded()))% \(reveal.home.abbreviation)")
            }
            .font(.interDigits(scaled(12), .heavy))
            GeometryReader { proxy in
                HStack(spacing: scaled(2)) {
                    Capsule().fill(awayColor).frame(width: max(4, (proxy.size.width - 2) * away))
                    Capsule().fill(homeColor)
                }
            }
            .frame(height: scaled(8))
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

extension View {
    /// On the television, a row the remote can rest on, so a list of them
    /// scrolls under it; Select on it runs `onSelect`, where there is one.
    /// On the phone, the row as it is.
    func gameStatsRowFocus(onSelect: (() -> Void)? = nil) -> some View {
        #if os(tvOS)
        return modifier(GameStatsRowFocus(onSelect: onSelect))
        #else
        return self
        #endif
    }
}

#if os(tvOS)
private struct GameStatsRowFocus: ViewModifier {
    let onSelect: (() -> Void)?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .contentShape(shape)
            .lineupFocusLayer(focused, in: shape)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onTapGesture { onSelect?() }
            .animation(.easeOut(duration: 0.16), value: focused)
    }
}
#endif
