import SwiftUI
import UIKit

/// The sport the Sports tab is showing, on one pill. A strip of eight logos
/// asked to be read; this says the one that is chosen, and the rest are a
/// tap away.
struct MobileLeagueMenuButton: View {
    let league: SportsLeague?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // A league's mark when one is chosen. Every league needs no
                // icon: the words say it, and the pill stays small.
                if let league { MobileLeagueLogo(league: league, size: 22) }
                else { LineupIconTile(symbol: "sportscourt.fill", size: 22) }
                Text(MobileLeagueMenu.title(league))
                    .font(.inter(15, .bold))
                    .foregroundStyle(LineupPresentationStyle.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(LineupPresentationStyle.secondary)
                    .rotationEffect(.degrees(isOpen ? -180 : 0))
            }
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(height: 36)
            // A panel's own fill, a step lighter while its list is open.
            .background(isOpen ? LineupPresentationStyle.card : LineupPresentationStyle.row, in: Capsule())
            .overlay(Capsule().strokeBorder(isOpen ? LineupStyle.highlight.opacity(0.4) : LineupPresentationStyle.divider, lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(MobileCardButtonStyle())
        .accessibilityLabel("Sport: \(MobileLeagueMenu.title(league))")
        .accessibilityHint(isOpen ? "Closes the list of sports" : "Shows the list of sports")
    }
}

/// Every league, dropped from the pill: its mark, its name, and what it has
/// on, with the chosen one ticked. Each league is a card like a game's on
/// the Sports tab, filled with the colours of its own mark.
struct MobileLeagueMenu: View {
    struct Entry: Identifiable {
        let league: SportsLeague?
        let games: Int
        let live: Int
        var id: String { league?.rawValue ?? "all" }
    }

    let entries: [Entry]
    let selected: SportsLeague?
    /// The room under the header; past it the list scrolls.
    let maxHeight: CGFloat
    let onChoose: (SportsLeague?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    static let rowHeight: CGFloat = 58
    /// Half the gap between two cards, kept inside each row's height.
    private static let cardInset: CGFloat = 3
    /// Wide enough for "12 GAMES" and "1 EVENT", so every count ends on the
    /// same line and the names keep the rest.
    private static let tallyWidth: CGFloat = 82
    private static let inset: CGFloat = 8
    /// The panel's header and its hairline, above the list.
    private static let headerHeight: CGFloat = 46

    static func title(_ league: SportsLeague?) -> String {
        guard let league else { return "All Sports" }
        return league == .ncaaf ? "College Football" : league.shortName
    }

    static func subtitle(_ league: SportsLeague?) -> String {
        guard let league else { return "Every league" }
        return league == .ncaaf ? "NCAA" : league.fullName
    }

    var body: some View {
        let shape = LineupPanelStyle.shape
        let content = CGFloat(entries.count) * Self.rowHeight + Self.inset * 2 + 9
        // A panel like every other: its header and hairline inside it, then
        // the leagues.
        VStack(spacing: 0) {
            LineupPresentationHeading(title: "Sports", symbol: "sportscourt", compact: true)
                .padding(.horizontal, LineupPanelStyle.inset)
                .frame(height: Self.headerHeight - 1)
            Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1)
                .padding(.horizontal, LineupPanelStyle.inset)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry)
                            .opacity(shown ? 1 : 0)
                            .offset(y: shown || reduceMotion ? 0 : -6)
                            .animation(shown ? (reduceMotion ? .easeOut(duration: 0.15)
                                       : .spring(response: 0.32, dampingFraction: 0.88).delay(Double(index) * 0.015))
                                       : nil, value: shown)
                        // Every league, then each of them.
                        if index == 0 {
                            Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                        }
                    }
                }
                .padding(Self.inset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .frame(height: min(content, max(0, maxHeight - Self.headerHeight)))
        }
        .mobileMenuSurface(shape)
        .lineupPresentation()
        .shadow(color: .black.opacity(MobileMenuGlass.shadow), radius: 24, y: 12)
        .onAppear { shown = true }
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ entry: Entry) -> some View {
        let isSelected = entry.league == selected
        let quiet = entry.games == 0 && !isSelected
        let card = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return Button { onChoose(entry.league) } label: {
            HStack(spacing: 11) {
                // The mark straight on the panel, as it sits on a game's
                // card. Every league has none; its name keeps to the column
                // the leagues' names start on, as a system menu does.
                Group {
                    if let league = entry.league { MobileLeagueLogo(league: league, size: 28) }
                    else { Color.clear }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(entry.league))
                        .font(.inter(16, .bold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(Self.subtitle(entry.league))
                        .font(.inter(12, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
                Spacer(minLength: 6)
                tally(entry)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: Self.tallyWidth, alignment: .trailing)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(LineupStyle.highlight)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: Self.rowHeight - Self.cardInset * 2)
            // A game's card: its colours across it, left to right, under
            // the same faint edge. The chosen one is a little stronger as
            // well as ticked.
            .background(LinearGradient(colors: Self.fill(entry.league, selected: isSelected),
                                       startPoint: .leading, endPoint: .trailing), in: card)
            .overlay(card.strokeBorder(Color.white.opacity(isSelected ? 0.14 : 0.045), lineWidth: 1))
            .contentShape(card)
            .padding(.vertical, Self.cardInset)
            .opacity(quiet ? 0.45 : 1)
        }
        .buttonStyle(MobileLeagueRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.title(entry.league)), \(spokenTally(entry))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The colours a league's card is filled with, from its mark. Every
    /// league takes the green of the Sports mark.
    static func fill(_ league: SportsLeague?, selected: Bool) -> [Color] {
        let strength = selected ? 0.36 : 0.26
        let stops = (league?.markColors ?? ["#30D158"]).compactMap { stop($0, strength: strength) }
        // A gradient needs two stops; a mark of one colour fills its card evenly.
        return stops.count == 1 ? stops + stops : stops
    }

    /// One of a mark's colours as its card shows it. A colour keeps its hue
    /// and saturation and is brightened as far as the dark panel needs: the
    /// lift a game's card uses mixes in white, which turned navy to slate.
    /// White, silver and black are a pale sheen at half the strength, so they
    /// light the card without greying it.
    private static func stop(_ hex: String, strength: Double) -> Color? {
        guard hex.count == 7, let value = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        let color = UIColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                            blue: CGFloat(value & 0xff) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.15 {
            return Color(white: Double(max(brightness, 0.6))).opacity(strength / 2)
        }
        return Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(max(brightness, 0.85)))
            .opacity(strength)
    }

    /// What it has on: how many are live, else how many are still to come.
    @ViewBuilder
    private func tally(_ entry: Entry) -> some View {
        if entry.live > 0 {
            HStack(spacing: 5) {
                MobileLiveDot()
                Text("\(entry.live) LIVE").font(.inter(11, .heavy)).tracking(0.4)
            }
            .foregroundStyle(LineupStyle.liveStatus)
        } else {
            Text(entry.games == 0 ? "NONE" : "\(entry.games) \(noun(entry, entry.games))")
                .font(.inter(11, .heavy)).tracking(0.4)
                .foregroundStyle(LineupPresentationStyle.secondary)
        }
    }

    private func noun(_ entry: Entry, _ count: Int) -> String {
        let one: String
        // A tennis tab lists tournaments, as UFC lists fight nights.
        if entry.league?.isTennis == true || entry.league == .ufc || entry.league?.isRacing == true { one = "EVENT" }
        else { one = "GAME" }
        return count == 1 ? one : one + "S"
    }

    private func spokenTally(_ entry: Entry) -> String {
        if entry.live > 0 { return "\(entry.live) live" }
        return entry.games == 0 ? "nothing scheduled" : "\(entry.games) \(noun(entry, entry.games).lowercased())"
    }
}

/// A card pressed in, as a game's card gives under a finger.
private struct MobileLeagueRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

extension SportsLeague {
    /// The colours of the league's own mark, in the order they run across
    /// it. ATP and WTA draw their marks in white here, so theirs add the
    /// tours' own colours, and the soccer ball is black and white.
    var markColors: [String] {
        switch self {
        case .nfl: ["#013369", "#D50A0A", "#FFFFFF"]
        case .nba: ["#1D428A", "#C8102E", "#FFFFFF"]
        case .nhl: ["#111111", "#A2AAAD", "#FFFFFF"]
        case .mlb: ["#041E42", "#BF0D3E", "#FFFFFF"]
        case .ncaaf: ["#0078C0", "#FFFFFF"]
        case .ufc: ["#D20A0A"]
        case .atp: ["#002865", "#FFFFFF"]
        case .wta: ["#5B2C8F", "#FFFFFF"]
        case .soccer: ["#FFFFFF", "#111111"]
        case .f1: ["#E10600"]
        case .nascar: ["#FFD100", "#E4002B", "#007AC2"]
        }
    }
}
