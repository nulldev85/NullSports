import SwiftUI

/// Settings and game menus share SportsLibrary's provider-scoped follows.
/// This directory is independent of today's schedule and network state.
struct SportsTeamsSettingsView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedLeague: SportsLeague? = .nfl
    private let directory = SportsTeamDirectory.bundled

    var body: some View {
        #if os(tvOS)
        television
        #else
        phone
        #endif
    }

    private var savingNote: String {
        library.activeProfile.map { "Saved for \($0.name). Your teams appear in Sports when they play." }
            ?? "Add an IPTV provider in Settings to save your teams."
    }

    #if os(tvOS)
    private var visibleTeams: [FollowedTeam] {
        if let selectedLeague {
            return directory.teams(in: selectedLeague, matching: query).map(\.followedTeam)
        }
        return library.followedTeams.teams.filter {
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ($0.name + " " + $0.abbreviation + " " + $0.league).localizedStandardContains(query)
        }
    }

    private var television: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .top, spacing: 30) {
                PageTitle(eyebrow: "Settings", title: "My Teams",
                          detail: "Choose a league and follow your teams, even when they aren’t playing.")
                Spacer(minLength: 20)
                Button("Done") { dismiss() }.lineupButtonStyle()
            }
            Text(savingNote).font(.inter(19)).foregroundStyle(LineupStyle.secondary)
            HStack(alignment: .top, spacing: 36) {
                VStack(spacing: 12) {
                    leagueChoice(nil)
                    ForEach(SportsTeamDirectory.leagues) { league in leagueChoice(league) }
                }
                .padding(18)
                .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(width: 300)
                .focusSection()
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text(selectedLeague.map(SportsTeamDirectory.title) ?? "Following").font(.inter(30, .bold))
                        Spacer()
                        Text("\(visibleTeams.count) \(visibleTeams.count == 1 ? "team" : "teams")")
                            .font(.inter(19)).foregroundStyle(LineupStyle.secondary)
                    }
                    TextField("Search teams", text: $query)
                        .font(.inter(22)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(18)
                        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("lineup.teams.search")
                    if visibleTeams.isEmpty {
                        LineupUnavailableView(query.isEmpty ? "No teams followed yet" : "No matching teams",
                            systemImage: "star",
                            description: Text(query.isEmpty ? "Choose a league to add your teams." : "Try another team name or abbreviation."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 20) {
                                ForEach(visibleTeams) { team in SportsTeamFollowButton(team: team, showsLeague: selectedLeague == nil) }
                            }
                            .padding(10)
                        }
                    }
                }
                .focusSection()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 80).padding(.vertical, 48)
        .foregroundStyle(LineupStyle.text)
        .background(LineupStyle.background.ignoresSafeArea())
        .onExitCommand { dismiss() }
    }

    private func leagueChoice(_ league: SportsLeague?) -> some View {
        let chosen = league == selectedLeague
        let count = league.map { value in library.followedTeams.teams.filter { $0.league == value.rawValue.uppercased() }.count }
            ?? library.followedTeams.count
        return TVSelectable(scale: 1.02, fillRadius: 14, action: {
            selectedLeague = league
            query = ""
        }, requestInitialFocus: league == .nfl) {
            HStack(spacing: 14) {
                if let league { SportsTeamLeagueLogo(league: league, size: 42) }
                else { LineupIconTile(symbol: "star.fill", size: 42) }
                Text(league.map(SportsTeamDirectory.title) ?? "Following").font(.inter(21, .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if count > 0 { Text(count.formatted()).font(.inter(18, .bold)).foregroundStyle(LineupStyle.highlight) }
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 80)
            .background(chosen ? LineupPanelStyle.well : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(chosen ? LineupStyle.highlight : .clear, lineWidth: 2)
            }
        }
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : [.isButton])
    }
    #else
    private var phone: some View {
        List {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !library.followedTeams.isEmpty {
                    Section {
                        ForEach(library.followedTeams.teams) { team in SportsTeamFollowButton(team: team, showsLeague: true) }
                    } header: { Text("Following").lineupSettingsHeader() }
                    .lineupSettingsRows()
                }
                Section {
                    ForEach(SportsTeamDirectory.leagues) { league in
                        NavigationLink {
                            SportsLeagueTeamsView(league: league)
                        } label: {
                            HStack(spacing: 14) {
                                SportsTeamLeagueLogo(league: league, size: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(SportsTeamDirectory.title(league)).font(.inter(17, .semibold))
                                    Text(league == .ncaaf ? "FBS and FCS" : league.fullName)
                                        .font(.inter(13)).foregroundStyle(LineupPanelStyle.listValue)
                                }
                                Spacer(minLength: 8)
                                Text(directory.teams(in: league).count.formatted())
                                    .font(.inter(15)).foregroundStyle(LineupPanelStyle.listValue)
                            }
                            .foregroundStyle(LineupStyle.text).padding(.vertical, 4)
                        }
                    }
                } header: { Text("Browse Leagues").lineupSettingsHeader() }
                  footer: { Text(savingNote).lineupSettingsFooter() }
                .lineupSettingsRows()
            } else {
                let results = directory.teams(matching: query)
                Section {
                    if results.isEmpty { Text("No matching teams. Try a name or abbreviation.").foregroundStyle(LineupPanelStyle.listValue) }
                    ForEach(results) { team in SportsTeamFollowButton(team: team.followedTeam, showsLeague: true) }
                } header: { Text("Teams").lineupSettingsHeader() }
                .lineupSettingsRows()
            }
        }
        .lineupSettingsList()
        .navigationTitle("My Teams")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find a team or league")
    }
    #endif
}

#if !os(tvOS)
private struct SportsLeagueTeamsView: View {
    let league: SportsLeague
    @State private var query = ""
    private var teams: [SportsTeamDirectory.Team] { SportsTeamDirectory.bundled.teams(in: league, matching: query) }

    var body: some View {
        List {
            if teams.isEmpty { Text("No matching teams. Try a name or abbreviation.").foregroundStyle(LineupPanelStyle.listValue) }
            if league == .ncaaf {
                ForEach(["FBS", "FCS"], id: \.self) { division in
                    let values = teams.filter { $0.division == division }
                    if !values.isEmpty {
                        Section {
                            ForEach(values) { team in SportsTeamFollowButton(team: team.followedTeam) }
                        } header: { Text(division).lineupSettingsHeader() }
                        .lineupSettingsRows()
                    }
                }
            } else {
                Section {
                    ForEach(teams) { team in SportsTeamFollowButton(team: team.followedTeam) }
                } header: {
                    HStack(spacing: 10) {
                        SportsTeamLeagueLogo(league: league, size: 26)
                        Text(SportsTeamDirectory.title(league)).lineupSettingsHeader()
                    }
                }
                .lineupSettingsRows()
            }
        }
        .lineupSettingsList()
        .navigationTitle(SportsTeamDirectory.title(league))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find a team")
    }
}
#endif

private struct SportsTeamLeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat
    var body: some View {
        Image("League-\(league.rawValue)").resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct SportsTeamFollowButton: View {
    @EnvironmentObject private var library: SportsLibrary
    let team: FollowedTeam
    var showsLeague = false
    private var following: Bool { library.isFollowing(team.key) }

    var body: some View {
        #if os(tvOS)
        TVSelectable(scale: 1.015, fillRadius: 18, action: { library.toggleFollow(team) }) {
            row.padding(20).frame(maxWidth: .infinity, minHeight: 124)
                .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .disabled(library.activeProfile == nil)
        .accessibilityLabel(team.name)
        .accessibilityValue(following ? "Following" : "Not following")
        .accessibilityHint(following ? "Remove from My Teams" : "Add to My Teams")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("lineup.teams.\(team.id)")
        #else
        Button { library.toggleFollow(team) } label: { row.padding(.vertical, 6) }
            .buttonStyle(MobileCardButtonStyle())
            .disabled(library.activeProfile == nil)
            .accessibilityLabel(team.name)
            .accessibilityValue(following ? "Following" : "Not following")
            .accessibilityHint(following ? "Remove from My Teams" : "Add to My Teams")
            .accessibilityIdentifier("lineup.teams.\(team.id)")
        #endif
    }

    private var row: some View {
        #if os(tvOS)
        let badgeSize: CGFloat = 58
        let nameSize: CGFloat = 23
        let detailSize: CGFloat = 17
        #else
        let badgeSize: CGFloat = 42
        let nameSize: CGFloat = 17
        let detailSize: CGFloat = 13
        #endif
        return HStack(spacing: 14) {
            TeamBadge(url: team.logo, fallback: team.abbreviation, size: badgeSize, tight: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(team.name).font(.inter(nameSize, .semibold)).foregroundStyle(LineupStyle.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(showsLeague ? "\(team.league) · \(team.abbreviation)" : team.abbreviation)
                    .font(.inter(detailSize)).foregroundStyle(LineupPanelStyle.listValue).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: following ? "star.fill" : "star")
                .font(.system(size: nameSize + 3, weight: .semibold))
                .foregroundStyle(following ? LineupStyle.highlight : LineupPanelStyle.listValue)
                .frame(width: 30)
        }
        .contentShape(Rectangle())
    }
}
