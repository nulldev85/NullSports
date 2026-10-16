import SwiftUI

/// Competition crests and series marks retain their original colors and
/// aspect ratio. Soccer itself has no league logo; its competitions do.
struct SportsMark: View {
    let league: SportsLeague
    var competition: SportsCompetition? = nil
    let size: CGFloat

    var body: some View {
        Group {
            if let competition {
                LineupArtView(url: URL(string: competition.logo), width: size) { image in
                    if let image { image.resizable().scaledToFit() }
                    else { Image(systemName: "soccerball").resizable().scaledToFit().foregroundStyle(LineupStyle.secondary) }
                }
            } else if league == .soccer {
                Image(systemName: "soccerball").resizable().scaledToFit().foregroundStyle(LineupStyle.text)
            } else {
                if league == .nascar {
                    Image("League-nascar").resizable().scaledToFit().padding(3)
                        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                } else if league == .f1 {
                    Image("League-f1").resizable().scaledToFill()
                        .frame(width: size, height: size * 0.36).clipped()
                } else {
                    Image("League-\(league.rawValue)").resizable().scaledToFit()
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(competition?.name ?? league.fullName)
    }
}

/// The existing choice-panel style, shared by the Sports and My Teams pages.
struct SoccerCompetitionFilter: View {
    @Binding var selected: String?
    @State private var choosing = false
    private let competitions = SportsCompetitionCatalog.bundled.competitions
    private var current: SportsCompetition? { competitions.first { $0.id == selected } }

    var body: some View {
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, action: { choosing = true }) {
            label.padding(.horizontal, 16).frame(height: 48)
                .background(LineupPanelStyle.well, in: Capsule())
        }
        .tvChoices("Soccer competitions", symbol: "soccerball", isPresented: $choosing) {
            [TVChoice("All competitions", id: "all", isSelected: selected == nil) { selected = nil }]
                + competitions.map { competition in
                    TVChoice(competition.name, id: competition.id, isSelected: selected == competition.id) { selected = competition.id }
                }
        }
        #else
        Button { choosing = true } label: {
            label.padding(.horizontal, 10).frame(minHeight: 36)
                .background(LineupPanelStyle.well, in: Capsule())
        }
        .buttonStyle(MobileCardButtonStyle())
        .lineupChoices("Soccer competitions", symbol: "soccerball", isPresented: $choosing) {
            [MobileMenuItem("All competitions", id: "all", isSelected: selected == nil) { selected = nil }]
                + competitions.map { competition in
                    MobileMenuItem(competition.name, id: competition.id, isSelected: selected == competition.id) { selected = competition.id }
                }
        }
        #endif
    }

    private var label: some View {
        HStack(spacing: 8) {
            SportsMark(league: .soccer, competition: current, size: 22)
            Text(current?.shortName ?? "Competitions")
                .font(.inter(14, .bold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(LineupStyle.text)
        .accessibilityElement(children: .combine)
    }
}
