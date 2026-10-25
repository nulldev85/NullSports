#if os(tvOS)
import SwiftUI

/// A team's schedule, standing, roster, injuries and news, from ESPN: the
/// phone's team page across the whole screen. The team and its parts are
/// down the left, as Settings lists its own; what the chosen part holds is
/// on the right, a row at a time, so the list scrolls under the remote.
struct TVTeamPage: View {
    @Environment(SportsLibrary.self) private var library
    let target: MobileTeamPageTarget

    private enum Section: String, CaseIterable, Identifiable {
        case schedule = "Schedule", standings = "Standings", roster = "Roster", injuries = "Injuries", news = "News"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .schedule: "calendar"
            case .standings: "list.number"
            case .roster: "person.3.fill"
            case .injuries: "cross.case.fill"
            case .news: "newspaper.fill"
            }
        }
    }

    private enum Load<Value> {
        case loading, loaded(Value), failed
        var value: Value? { if case .loaded(let value) = self { return value } else { return nil } }
    }

    @State private var section: Section = .schedule
    @State private var info: TeamPageInfo?
    @State private var schedule: Load<[TeamPageGame]> = .loading
    @State private var standings: Load<TeamPageStandings> = .loading
    @State private var roster: Load<TeamPageParser.Roster> = .loading
    @State private var news: Load<[TeamPageArticle]> = .loading

    private var client: MobileTeamPageClient { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            sidebar.frame(width: 520).frame(maxHeight: .infinity, alignment: .top)
            ScrollView {
                content.padding(.horizontal, 14).padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90).padding(.top, 70)
        .foregroundStyle(LineupPresentationStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .task { info = await client.info(target.path) }
        .task(id: section) { await load(section) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            TeamBadge(url: info?.logo ?? target.logo, fallback: target.abbreviation, size: 110)
            Text(target.league == .ncaaf ? "COLLEGE FOOTBALL" : target.league.fullName.uppercased())
                .font(.inter(18, .heavy)).tracking(LineupPanelStyle.headerTracking)
                .foregroundStyle(LineupPanelStyle.caption)
                .padding(.top, 26)
            Text(info?.name ?? target.name).font(.inter(42, .bold)).lineLimit(2).minimumScaleFactor(0.7)
                .padding(.top, 6)
            let line = [info?.record, info?.standing].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty {
                Text(line).font(.inter(21, .medium)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                    .padding(.top, 6)
            }
            followButton.padding(.top, 26)
            VStack(spacing: 8) {
                ForEach(Section.allCases) { option in
                    TVSelectable(scale: LineupStyle.cardLift, drawsFocusChrome: false,
                                 action: { section = option },
                                 requestInitialFocus: option == .schedule) {
                        TVTeamPageSectionLabel(title: option.rawValue, symbol: option.symbol, selected: section == option)
                    }
                }
            }
            .padding(.top, 34)
        }
        .lineupFocusRegion()
    }

    private var followButton: some View {
        let following = library.isFollowing(target.followKey)
        return TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
            library.toggleFollow(FollowedTeam(key: target.followKey, name: target.name,
                                              abbreviation: target.abbreviation, logo: target.logo))
        }) {
            TVTeamPageFollowLabel(following: following)
        }
        .accessibilityLabel(following ? "Remove from My Teams" : "Add to My Teams")
    }

    // MARK: Sections

    @ViewBuilder
    private var content: some View {
        switch section {
        case .schedule:
            loaded(schedule, empty: "No games on ESPN's schedule for this team right now.") { games in
                scheduleView(games)
            }
        case .standings:
            loaded(standings, empty: "Standings aren't available for this team.") { table in
                standingsView(table)
            }
        case .roster:
            loaded(roster, empty: "The roster isn't available for this team.") { roster in
                rosterView(roster)
            }
        case .injuries:
            loaded(roster, empty: "Injury reports aren't available for this team.") { roster in
                injuriesView(roster)
            }
        case .news:
            loaded(news, empty: "No recent stories about this team.") { articles in
                newsView(articles)
            }
        }
    }

    @ViewBuilder
    private func loaded<Value, Shown: View>(_ load: Load<Value>, empty: String,
                                             @ViewBuilder shown: (Value) -> Shown) -> some View {
        switch load {
        case .loading:
            HStack(spacing: 14) {
                ProgressView().tint(LineupPresentationStyle.text)
                Text("Loading…").font(.inter(21)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 80)
        case .failed:
            message(empty, symbol: "sportscourt")
        case .loaded(let value):
            shown(value)
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 40, weight: .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
            Text(text).font(.inter(22)).foregroundStyle(LineupPresentationStyle.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80).padding(.horizontal, 40)
    }

    private func load(_ section: Section) async {
        switch section {
        // A part that failed is asked for again when it is chosen again.
        case .schedule:
            guard schedule.value == nil else { return }
            if let games = await client.schedule(target.path), !games.isEmpty { schedule = .loaded(games) }
            else { schedule = .failed }
        case .standings:
            guard standings.value == nil else { return }
            if let table = await client.standings(target.path) { standings = .loaded(table) }
            else { standings = .failed }
        case .roster, .injuries:
            guard roster.value == nil else { return }
            if let found = await client.roster(target.path), !found.groups.isEmpty { roster = .loaded(found) }
            else { roster = .failed }
        case .news:
            guard news.value == nil else { return }
            if let articles = await client.news(target.path), !articles.isEmpty { news = .loaded(articles) }
            else { news = .failed }
        }
    }

    // MARK: Schedule

    private func scheduleView(_ games: [TeamPageGame]) -> some View {
        let upcoming = games.filter { !$0.isFinished }.prefix(8)
        let results = games.filter(\.isFinished).suffix(12).reversed()
        return VStack(alignment: .leading, spacing: 28) {
            if !upcoming.isEmpty { panel("UP NEXT", rows: Array(upcoming), row: gameRow) }
            if !results.isEmpty { panel("RESULTS", rows: Array(results), row: gameRow) }
        }
    }

    private func gameRow(_ game: TeamPageGame) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(game.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.inter(20, .semibold)).foregroundStyle(LineupPanelStyle.caption)
                if let label = game.label {
                    Text(label).font(.inter(16, .medium)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
            }
            .frame(width: 150, alignment: .leading)
            Text(game.isHome ? "vs" : "@").font(.inter(20, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                .frame(width: 32)
            TeamBadge(url: game.opponentLogo ?? "", fallback: game.opponentAbbreviation, size: 44, tight: true)
            Text(game.opponent).font(.inter(23, .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                if game.isFinished, let ours = game.teamScore, let theirs = game.opponentScore {
                    HStack(spacing: 10) {
                        if let outcome = game.outcome {
                            Text(outcome.rawValue).font(.inter(21, .heavy))
                                .foregroundStyle(outcome == .win ? LineupStyle.positive
                                                 : outcome == .loss ? LineupStyle.live : LineupPresentationStyle.secondary)
                        }
                        Text("\(ours)–\(theirs)").font(.interDigits(23, .bold))
                    }
                } else if game.state == "in" {
                    Text(game.status).font(.inter(20, .bold)).foregroundStyle(LineupStyle.live).lineLimit(1)
                } else {
                    Text(game.date.formatted(date: .omitted, time: .shortened)).font(.inter(21, .semibold))
                }
                if !game.isFinished, let network = game.broadcast {
                    Text(network).font(.inter(16, .medium)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: Standings

    private func standingsView(_ table: TeamPageStandings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(table.group.uppercased()).font(.inter(17, .heavy)).tracking(LineupPanelStyle.headerTracking)
                    .foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                Spacer(minLength: 12)
                ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                    Text(column).font(.inter(17, .heavy)).foregroundStyle(LineupPresentationStyle.secondary)
                        .frame(width: columnWidth(table), alignment: .trailing)
                }
            }
            .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 10)
            ForEach(Array(table.rows.enumerated()), id: \.element.id) { index, row in
                let ours = row.id == target.path.teamID
                HStack(spacing: 16) {
                    Text("\(index + 1)").font(.interDigits(20, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                        .frame(width: 34, alignment: .leading)
                    TeamBadge(url: row.logo ?? "", fallback: row.abbreviation, size: 36, tight: true)
                    Text(table.columns.count > 6 ? row.abbreviation : row.name)
                        .font(.inter(21, ours ? .bold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                        Text(value).font(.interDigits(21, ours ? .bold : .regular))
                            .frame(width: columnWidth(table), alignment: .trailing)
                    }
                }
                .padding(.horizontal, 26).padding(.vertical, 12)
                .background(ours ? LineupStyle.highlight.opacity(0.18) : Color.clear)
                .lineupRowFocus()
                .accessibilityElement(children: .combine)
            }
            Color.clear.frame(height: 12)
        }
        .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
        .clipShape(LineupPanelStyle.shape)
    }

    private func columnWidth(_ table: TeamPageStandings) -> CGFloat {
        table.columns.count > 6 ? 64 : (table.columns.count > 3 ? 80 : 100)
    }

    // MARK: Roster and injuries

    private func rosterView(_ roster: TeamPageParser.Roster) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            if let coach = roster.coach {
                Text("Head coach: \(coach)").font(.inter(21, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                    .padding(.horizontal, 6)
            }
            ForEach(roster.groups) { group in
                panel(group.title.uppercased(), rows: group.players, row: playerRow)
            }
        }
    }

    private func playerRow(_ player: TeamPagePlayer) -> some View {
        HStack(spacing: 18) {
            Text(player.jersey.map { "#\($0)" } ?? "").font(.interDigits(20, .semibold))
                .foregroundStyle(LineupPresentationStyle.secondary).frame(width: 54, alignment: .leading)
            headshot(player)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.name).font(.inter(23, .semibold)).lineLimit(1)
                if let position = player.position {
                    Text(position).font(.inter(17, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                }
            }
            Spacer(minLength: 10)
            if let injury = player.injury { injuryTag(injury) }
        }
        .padding(.horizontal, 26).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func headshot(_ player: TeamPagePlayer) -> some View {
        AsyncImage(url: player.headshot.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.fill").font(.system(size: 22)).foregroundStyle(LineupPresentationStyle.secondary)
        }
        .frame(width: 54, height: 54)
        .background(LineupPresentationStyle.row)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private func injuriesView(_ roster: TeamPageParser.Roster) -> some View {
        let injured = roster.injured
        return Group {
            if injured.isEmpty {
                message("No injuries reported.", symbol: "cross.case")
            } else {
                panel("INJURY REPORT", rows: injured) { player in
                    HStack(spacing: 18) {
                        headshot(player)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.name).font(.inter(23, .semibold)).lineLimit(1)
                            Text([player.position, player.injuryDate.map {
                                $0.formatted(.dateTime.month(.abbreviated).day())
                            }].compactMap { $0 }.joined(separator: " · "))
                                .font(.inter(17, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                        }
                        Spacer(minLength: 10)
                        if let injury = player.injury { injuryTag(injury) }
                    }
                    .padding(.horizontal, 26).padding(.vertical, 13)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Out and on reserve in red; questionable, doubtful and day to day in
    /// amber; anything else as it is written, as on the phone.
    private func injuryTag(_ status: String) -> some View {
        let lowered = status.lowercased()
        let tint: Color = lowered.contains("out") || lowered.contains("reserve") || lowered.contains("suspend")
            ? LineupStyle.live
            : (lowered.contains("question") || lowered.contains("doubt") || lowered.contains("day")
               ? Color(red: 1, green: 0.74, blue: 0.25) : LineupPresentationStyle.secondary)
        return Text(status).font(.inter(18, .bold)).foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tint.opacity(0.15), in: Capsule())
            .lineLimit(1).fixedSize()
    }

    // MARK: News

    /// The stories themselves: the television has no browser to open them
    /// in, so each row carries its headline and summary in full.
    private func newsView(_ articles: [TeamPageArticle]) -> some View {
        panel("LATEST", rows: articles) { article in
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(article.headline).font(.inter(23, .semibold)).lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let summary = article.summary {
                        Text(summary).font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    if let published = article.published {
                        Text(published.formatted(.relative(presentation: .named)))
                            .font(.inter(16, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                    }
                }
                Spacer(minLength: 6)
                if let image = article.image.flatMap(URL.init(string:)) {
                    AsyncImage(url: image) { picture in
                        picture.resizable().scaledToFill()
                    } placeholder: { LineupPresentationStyle.row }
                    .frame(width: 192, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Panel

    /// A captioned panel of rows with hairlines between them. Each row takes
    /// the remote, so a long one scrolls.
    private func panel<Row: Identifiable, Shown: View>(_ title: String, rows: [Row],
                                                       row: @escaping (Row) -> Shown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.inter(17, .heavy)).tracking(LineupPanelStyle.headerTracking)
                .foregroundStyle(LineupPresentationStyle.secondary)
                .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1).padding(.leading, 26)
                }
                row(item).lineupRowFocus()
            }
            Color.clear.frame(height: 10)
        }
        .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
    }
}

/// One part of the page in the sidebar: its tile and name, lit while chosen.
private struct TVTeamPageSectionLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    let symbol: String
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 16) {
            LineupIconTile(symbol: symbol, size: 38)
            Text(title).font(.inter(23, .semibold))
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "chevron.right").font(.system(size: 18, weight: .bold))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
        }
        .padding(.horizontal, 18).frame(height: 66)
        .background(selected ? LineupPresentationStyle.row : LineupPresentationStyle.card, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

private struct TVTeamPageFollowLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let following: Bool

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 12) {
            Image(systemName: following ? "star.fill" : "star").font(.system(size: 21, weight: .bold))
                .foregroundStyle(following ? LineupStyle.highlight : LineupPresentationStyle.text)
            Text(following ? "In My Teams" : "Add to My Teams").font(.inter(21, .semibold))
        }
        .padding(.horizontal, 24).frame(height: 58)
        .background(LineupPresentationStyle.row, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}
#endif
