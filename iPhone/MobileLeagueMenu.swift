import SwiftUI

/// A league's mark, or the grid that stands for every league, in one frame.
struct MobileLeagueMark: View {
    let league: SportsLeague?
    let size: CGFloat

    var body: some View {
        if let league {
            MobileLeagueLogo(league: league, size: size)
        } else {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: size * 0.62))
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// The sport the Sports tab is showing, on one pill. A strip of eight logos
/// asked to be read; this says the one that is chosen, and the rest are a
/// tap away.
struct MobileLeagueMenuButton: View {
    let league: SportsLeague?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                MobileLeagueMark(league: league, size: 22)
                Text(MobileLeagueMenu.title(league))
                    .font(.inter(15, .semibold))
                    .foregroundStyle(LineupStyle.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LineupStyle.secondary)
                    .rotationEffect(.degrees(isOpen ? -180 : 0))
            }
            .padding(.leading, 9).padding(.trailing, 13)
            .frame(height: 36)
            .background(isOpen ? LineupStyle.focused : LineupStyle.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 0.5))
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

    static let rowHeight: CGFloat = 56
    private static let inset: CGFloat = 6

    static func title(_ league: SportsLeague?) -> String {
        guard let league else { return "All Sports" }
        return league == .ncaaf ? "College Football" : league.shortName
    }

    static func subtitle(_ league: SportsLeague?) -> String {
        guard let league else { return "Every league" }
        return league == .ncaaf ? "NCAA" : league.fullName
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let content = CGFloat(entries.count) * Self.rowHeight + Self.inset * 2 + 9
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown || reduceMotion ? 0 : -8)
                        .animation(reduceMotion ? .easeOut(duration: 0.15)
                                   : .spring(response: 0.36, dampingFraction: 0.86).delay(Double(index) * 0.02),
                                   value: shown)
                    // Every league, then each of them.
                    if index == 0 {
                        Rectangle().fill(LineupStyle.line).frame(height: 0.5)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                }
            }
            .padding(Self.inset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(height: min(content, maxHeight))
        .background(LineupStyle.raised, in: shape)
        .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 0.5))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .onAppear { shown = true }
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ entry: Entry) -> some View {
        let isSelected = entry.league == selected
        let quiet = entry.games == 0 && !isSelected
        return Button { onChoose(entry.league) } label: {
            HStack(spacing: 12) {
                MobileLeagueMark(league: entry.league, size: 26)
                    .frame(width: 40, height: 40)
                    .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(entry.league))
                        .font(.inter(15, .semibold)).foregroundStyle(LineupStyle.text)
                    Text(Self.subtitle(entry.league))
                        .font(.inter(11, .medium)).foregroundStyle(LineupStyle.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
                Spacer(minLength: 8)
                tally(entry)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LineupStyle.highlight)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .background(isSelected ? LineupStyle.focused : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                Text("\(entry.live) LIVE").font(.inter(10, .bold)).tracking(0.8)
            }
            .foregroundStyle(LineupStyle.liveStatus)
        } else {
            Text(entry.games == 0 ? "NONE" : "\(entry.games) \(noun(entry, entry.games))")
                .font(.inter(10, .bold)).tracking(0.8)
                .foregroundStyle(LineupStyle.secondary)
        }
    }

    private func noun(_ entry: Entry, _ count: Int) -> String {
        let one: String
        if entry.league?.isTennis == true { one = "MATCH" }
        else if entry.league == .ufc { one = "EVENT" }
        else { one = "GAME" }
        guard count != 1 else { return one }
        return one == "MATCH" ? "MATCHES" : one + "S"
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
            .background(configuration.isPressed ? LineupStyle.focused.opacity(0.7) : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
