import SwiftUI

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
                Text(MobileLeagueMenu.title(league))
                    .font(.inter(15, .bold))
                    .foregroundStyle(LineupStyle.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(LineupPanelStyle.quiet)
                    .rotationEffect(.degrees(isOpen ? -180 : 0))
            }
            .padding(.leading, league == nil ? 14 : 10).padding(.trailing, 12)
            .frame(height: 36)
            // A panel's own fill, a step lighter while its list is open.
            .background(isOpen ? LineupPanelStyle.well : LineupPanelStyle.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(MobileCardButtonStyle())
        .accessibilityLabel("Sport: \(MobileLeagueMenu.title(league))")
        .accessibilityHint(isOpen ? "Closes the list of sports" : "Shows the list of sports")
    }
}

/// Every league, dropped from the pill: its mark, its name, and what it has
/// on, with the chosen one ticked.
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

    static let rowHeight: CGFloat = 54
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
            LineupPanelHeader("Sports", systemImage: "sportscourt")
                .padding(.horizontal, LineupPanelStyle.inset)
                .frame(height: Self.headerHeight - 1)
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
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
                            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
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
        .background(LineupPanelStyle.fill, in: shape)
        // It floats over panels of its own colour, so it takes a hairline
        // of light round its edge and a deep shadow under it.
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        .onAppear { shown = true }
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ entry: Entry) -> some View {
        let isSelected = entry.league == selected
        let quiet = entry.games == 0 && !isSelected
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
                        .font(.inter(16, .bold)).foregroundStyle(LineupStyle.text)
                    Text(Self.subtitle(entry.league))
                        .font(.inter(12, .medium)).foregroundStyle(LineupPanelStyle.quiet)
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
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(isSelected ? LineupPanelStyle.well : .clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .opacity(quiet ? 0.45 : 1)
        }
        .buttonStyle(MobileLeagueRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.title(entry.league)), \(spokenTally(entry))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                .foregroundStyle(LineupPanelStyle.quiet)
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

/// A row pressed in: the grey of a chosen row, and a little give.
private struct MobileLeagueRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LineupPanelStyle.well.opacity(0.8) : .clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
