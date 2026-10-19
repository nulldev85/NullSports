import SwiftUI

struct RacingSessionDetails: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    let game: SportsGame
    private var current: SportsGame { library.gamesByLeague[game.league]?.first { $0.id == game.id } ?? game }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                SportsMark(league: current.league, size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.league.fullName.uppercased()).font(.inter(13, .heavy)).foregroundStyle(LineupPanelStyle.caption)
                    Text(current.eventName ?? current.league.fullName).font(.inter(25, .bold)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                #if os(tvOS)
                Button("Done") { dismiss() }.lineupButtonStyle()
                #else
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                        .frame(width: 44, height: 44)
                        .lineupGlassControl(Circle())
                }.buttonStyle(.plain).accessibilityLabel("Close")
                #endif
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(current.race?.title ?? "Race").font(.inter(22, .bold)).foregroundStyle(LineupStyle.highlight)
                        Text(current.start.formatted(date: .abbreviated, time: .shortened)).font(.inter(18, .semibold))
                        if let place = current.placeLine { Text(place).font(.inter(17)).foregroundStyle(LineupStyle.secondary) }
                        if !current.status.isEmpty { Text(current.status).font(.inter(17, .semibold)) }
                        if !current.broadcast.isEmpty { Text(current.broadcast).font(.inter(15)).foregroundStyle(LineupStyle.secondary) }
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("DRIVERS").font(.inter(15, .heavy)).tracking(LineupPanelStyle.headerTracking)
                            .foregroundStyle(LineupPanelStyle.caption)
                        if let entrants = current.race?.entrants, !entrants.isEmpty {
                            LazyVStack(spacing: 14) {
                                ForEach(entrants) { entrant in
                                    RacingEntrantRow(entrant: entrant)
                                }
                            }
                        } else {
                            Text("Driver information isn’t available for this session yet.")
                                .font(.inter(17)).foregroundStyle(LineupStyle.secondary)
                        }
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
                }
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(24).frame(maxWidth: 1000, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .foregroundStyle(LineupStyle.text)
        .background(LineupStyle.background.ignoresSafeArea())
        #if os(tvOS)
        .padding(.horizontal, 100).padding(.vertical, 50)
        .onExitCommand { dismiss() }
        #else
        .presentationDetents([.large])
        #endif
    }
}

private struct RacingEntrantRow: View {
    let entrant: RacingSession.Entrant
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 14) {
            if let position = entrant.position { Text("\(position)").font(.interDigits(18, .bold)).frame(width: 30) }
            if let flag = entrant.flag { TeamBadge(url: flag, fallback: "", size: 30, tight: true) }
            Text(entrant.name).font(.inter(18, .semibold))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(focused ? LineupPanelStyle.well : .clear, in: RoundedRectangle(cornerRadius: 12))
        #if os(tvOS)
        .focusable().focused($focused).focusEffectDisabled()
        #endif
        .accessibilityElement(children: .combine)
    }
}
