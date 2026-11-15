import SwiftUI

/// A switch for each sport: on to show it in the Sports tab, off to leave it
/// out. Reached from the Sports tab's list of leagues and from Settings.
struct MobileSportsVisibilityView: View {
    @AppStorage(SportsVisibility.storageKey) private var hiddenRaw = ""
    @Environment(\.dismiss) private var dismiss
    /// Presented over the Sports tab, with its own way out.
    var showsDone = false

    var body: some View {
        let hidden = SportsVisibility.hidden(hiddenRaw)
        let lastShown = hidden.count == SportsLeague.allCases.count - 1
        List {
            Section {
                ForEach(SportsLeague.allCases) { league in
                    let shown = !hidden.contains(league)
                    Toggle(isOn: Binding(get: { shown }, set: { on in
                        hiddenRaw = SportsVisibility.setting(league, hidden: !on, in: hiddenRaw)
                    })) {
                        HStack(spacing: 12) {
                            MobileLeagueLogo(league: league, size: 28)
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(MobileLeagueMenu.title(league))
                                    .font(.inter(17, .medium)).foregroundStyle(LineupStyle.text)
                                Text(MobileLeagueMenu.subtitle(league))
                                    .font(.inter(12)).foregroundStyle(LineupPresentationStyle.secondary)
                            }
                            .lineLimit(1)
                        }
                    }
                    .tint(LineupStyle.highlight)
                    .disabled(shown && lastShown)
                }
            } footer: {
                Text("Sports you turn off are left out of the Sports tab, its list of leagues and the live scores. Teams you follow in them stay followed.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .navigationTitle("Sports Shown").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                LineupToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.buttonStyle(LineupBarButtonStyle())
                }
            }
        }
    }
}

/// Which Top 25 sits beside college football teams.
struct MobileCollegePollView: View {
    @AppStorage(CollegeFootballRankings.Poll.storageKey) private var poll = CollegeFootballRankings.Poll.ap.rawValue
    var onChange: () -> Void = {}

    var body: some View {
        List {
            Section {
                ForEach(CollegeFootballRankings.Poll.allCases) { choice in
                    Button {
                        poll = choice.rawValue
                        onChange()
                    } label: {
                        HStack {
                            Text(choice.title).font(.inter(17, .medium)).foregroundStyle(LineupStyle.text)
                            Spacer()
                            if poll == choice.rawValue {
                                Image(systemName: "checkmark").foregroundStyle(LineupStyle.highlight)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(poll == choice.rawValue ? .isSelected : [])
                }
            } footer: {
                Text("The latest week of the poll you choose appears beside college football and basketball teams. Playoff Rankings are football's alone and start in November; until then, and for basketball, the AP Top 25 stands in.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .navigationTitle("College Top 25").navigationBarTitleDisplayMode(.inline)
    }
}
