import SwiftUI

/// A team's schedule, standing, roster, injuries and news, from ESPN.
struct MobileTeamPage: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let target: MobileTeamPageTarget

    private enum Section: String, CaseIterable, Identifiable {
        case schedule = "Schedule", standings = "Standings", roster = "Roster", injuries = "Injuries", news = "News"
        var id: String { rawValue }
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
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Section.allCases) { option in
                        Button { section = option } label: { Text(option.rawValue).lineupChip(section == option) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
            ScrollView {
                content.padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 20).padding(.top, 24)
        .foregroundStyle(LineupPresentationStyle.text)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationBackground(LineupPresentationStyle.ground)
        .presentationDragIndicator(.visible)
        .task { info = await client.info(target.path) }
        .task(id: section) { await load(section) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            TeamBadge(url: info?.logo ?? target.logo, fallback: target.abbreviation, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(target.league == .ncaaf ? "COLLEGE FOOTBALL" : target.league.fullName.uppercased())
                    .font(.inter(12, .heavy)).tracking(LineupPanelStyle.headerTracking)
                    .foregroundStyle(LineupPanelStyle.caption)
                Text(info?.name ?? target.name).font(.inter(23, .bold)).lineLimit(2).minimumScaleFactor(0.8)
                let line = [info?.record, info?.standing].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(line).font(.inter(14, .medium)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            let following = library.isFollowing(target.followKey)
            Button {
                library.toggleFollow(FollowedTeam(key: target.followKey, name: target.name,
                                                  abbreviation: target.abbreviation, logo: target.logo))
            } label: {
                Image(systemName: following ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(following ? LineupStyle.highlight : LineupPresentationStyle.text)
                    .frame(width: 44, height: 44)
                    .lineupGlassControl(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(following ? "Remove from My Teams" : "Add to My Teams")
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .lineupGlassControl(Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Close")
        }
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
            HStack(spacing: 10) {
                ProgressView().tint(LineupPresentationStyle.text)
                Text("Loading…").font(.inter(14)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
        case .failed:
            message(empty, symbol: "sportscourt")
        case .loaded(let value):
            shown(value)
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
            Text(text).font(.inter(15)).foregroundStyle(LineupPresentationStyle.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 20)
    }

    private func load(_ section: Section) async {
        switch section {
        // A part that failed is asked for again when its tab is opened again.
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
        return VStack(alignment: .leading, spacing: 18) {
            if !upcoming.isEmpty { panel("UP NEXT", rows: Array(upcoming), row: gameRow) }
            if !results.isEmpty { panel("RESULTS", rows: Array(results), row: gameRow) }
        }
    }

    private func gameRow(_ game: TeamPageGame) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.inter(13, .semibold)).foregroundStyle(LineupPanelStyle.caption)
                if let label = game.label {
                    Text(label).font(.inter(11, .medium)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
            }
            .frame(width: 92, alignment: .leading)
            Text(game.isHome ? "vs" : "@").font(.inter(13, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                .frame(width: 20)
            TeamBadge(url: game.opponentLogo ?? "", fallback: game.opponentAbbreviation, size: 28, tight: true)
            Text(game.opponent).font(.inter(15, .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                if game.isFinished, let ours = game.teamScore, let theirs = game.opponentScore {
                    HStack(spacing: 6) {
                        if let outcome = game.outcome {
                            Text(outcome.rawValue).font(.inter(14, .heavy))
                                .foregroundStyle(outcome == .win ? LineupStyle.positive
                                                 : outcome == .loss ? LineupStyle.live : LineupPresentationStyle.secondary)
                        }
                        Text("\(ours)–\(theirs)").font(.interDigits(15, .bold))
                    }
                } else if game.state == "in" {
                    Text(game.status).font(.inter(13, .bold)).foregroundStyle(LineupStyle.live).lineLimit(1)
                } else {
                    Text(game.date.formatted(date: .omitted, time: .shortened)).font(.inter(14, .semibold))
                }
                if !game.isFinished, let network = game.broadcast {
                    Text(network).font(.inter(11, .medium)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    // MARK: Standings

    private func standingsView(_ table: TeamPageStandings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(table.group.uppercased()).font(.inter(11, .heavy)).tracking(LineupPanelStyle.headerTracking)
                    .foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                Spacer(minLength: 8)
                ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                    Text(column).font(.inter(11, .heavy)).foregroundStyle(LineupPresentationStyle.secondary)
                        .frame(width: columnWidth(table), alignment: .trailing)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            ForEach(Array(table.rows.enumerated()), id: \.element.id) { index, row in
                let ours = row.id == target.path.teamID
                HStack(spacing: 10) {
                    Text("\(index + 1)").font(.interDigits(13, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                        .frame(width: 22, alignment: .leading)
                    TeamBadge(url: row.logo ?? "", fallback: row.abbreviation, size: 24, tight: true)
                    Text(table.columns.count > 4 ? row.abbreviation : row.name)
                        .font(.inter(14, ours ? .bold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                        Text(value).font(.interDigits(14, ours ? .bold : .regular))
                            .frame(width: columnWidth(table), alignment: .trailing)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(ours ? LineupStyle.highlight.opacity(0.18) : Color.clear)
                .accessibilityElement(children: .combine)
            }
            Color.clear.frame(height: 8)
        }
        .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
        .clipShape(LineupPanelStyle.shape)
    }

    private func columnWidth(_ table: TeamPageStandings) -> CGFloat {
        table.columns.count > 4 ? 30 : (table.columns.count > 2 ? 42 : 56)
    }

    // MARK: Roster and injuries

    private func rosterView(_ roster: TeamPageParser.Roster) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let coach = roster.coach {
                Text("Head coach: \(coach)").font(.inter(14, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                    .padding(.horizontal, 4)
            }
            ForEach(roster.groups) { group in
                panel(group.title.uppercased(), rows: group.players, row: playerRow)
            }
        }
    }

    private func playerRow(_ player: TeamPagePlayer) -> some View {
        HStack(spacing: 12) {
            Text(player.jersey.map { "#\($0)" } ?? "").font(.interDigits(13, .semibold))
                .foregroundStyle(LineupPresentationStyle.secondary).frame(width: 34, alignment: .leading)
            headshot(player)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.name).font(.inter(15, .semibold)).lineLimit(1)
                if let position = player.position {
                    Text(position).font(.inter(12, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                }
            }
            Spacer(minLength: 6)
            if let injury = player.injury { injuryTag(injury) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func headshot(_ player: TeamPagePlayer) -> some View {
        AsyncImage(url: player.headshot.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(LineupPresentationStyle.secondary)
        }
        .frame(width: 34, height: 34)
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
                    HStack(spacing: 12) {
                        headshot(player)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.name).font(.inter(15, .semibold)).lineLimit(1)
                            Text([player.position, player.injuryDate.map {
                                $0.formatted(.dateTime.month(.abbreviated).day())
                            }].compactMap { $0 }.joined(separator: " · "))
                                .font(.inter(12, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                        }
                        Spacer(minLength: 6)
                        if let injury = player.injury { injuryTag(injury) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Out and on reserve in red; questionable, doubtful and day to day in
    /// amber; anything else as it is written.
    private func injuryTag(_ status: String) -> some View {
        let lowered = status.lowercased()
        let tint: Color = lowered.contains("out") || lowered.contains("reserve") || lowered.contains("suspend")
            ? LineupStyle.live
            : (lowered.contains("question") || lowered.contains("doubt") || lowered.contains("day")
               ? Color(red: 1, green: 0.74, blue: 0.25) : LineupPresentationStyle.secondary)
        return Text(status).font(.inter(12, .bold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .lineLimit(1).fixedSize()
    }

    // MARK: News

    private func newsView(_ articles: [TeamPageArticle]) -> some View {
        panel("LATEST", rows: articles) { article in
            Button {
                if let link = article.link { openURL(link) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.headline).font(.inter(15, .semibold)).lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if let summary = article.summary {
                            Text(summary).font(.inter(13)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        if let published = article.published {
                            Text(published.formatted(.relative(presentation: .named)))
                                .font(.inter(11, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if let image = article.image.flatMap(URL.init(string:)) {
                        AsyncImage(url: image) { picture in
                            picture.resizable().scaledToFill()
                        } placeholder: { LineupPresentationStyle.row }
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(article.link == nil)
        }
    }

    // MARK: Panel

    /// A captioned panel of rows with hairlines between them, as the stats
    /// panel's courts are.
    private func panel<Row: Identifiable, Shown: View>(_ title: String, rows: [Row],
                                                       row: @escaping (Row) -> Shown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.inter(11, .heavy)).tracking(LineupPanelStyle.headerTracking)
                .foregroundStyle(LineupPresentationStyle.secondary)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1).padding(.leading, 16)
                }
                row(item)
            }
            Color.clear.frame(height: 6)
        }
        .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
    }
}
