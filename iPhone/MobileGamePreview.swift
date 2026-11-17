import SwiftUI

/// A game that has not started, opened from Sports: who is playing, when and
/// where, where it is on in your guide, a reminder, and how each side has
/// been doing -- in place of a note that it has not started yet.
struct MobileGamePreview: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var reminders: GameReminders
    let library: SportsLibrary
    let game: SportsGame
    /// A channel chosen from Where to Watch: played as any channel picked for
    /// a game is, once this page has gone.
    let onPick: (MobileProviderChannel) -> Void

    @State private var channels: [MobileProviderChannel] = []
    /// Each playlist's feeds of the network the game is on, for when the
    /// guide does not name it yet.
    @State private var networkChannels: [MobileProviderChannel] = []
    @State private var findingChannels = true
    @State private var awayForm: [TeamPageGame.Outcome]?
    @State private var homeForm: [TeamPageGame.Outcome]?

    /// The game as the schedule has it now: a start time moved, a rank added.
    private var current: SportsGame {
        library.providerRoot.gamesByLeague[game.league]?.first { $0.id == game.id } ?? game
    }

    private var awayColor: Color {
        MobileTeamColor.readable(current.awayColor) ?? LineupStyle.leagueColor(current.league)
    }
    private var homeColor: Color { MobileTeamColor.readable(current.homeColor) ?? awayColor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                details
                whereToWatch
                remindButton
                if !current.isEvent { form }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack(alignment: .top) {
                LineupPresentationStyle.ground
                // The teams' colours, as a game's card carries them, fading
                // into the page.
                LinearGradient(colors: [awayColor.opacity(0.3), homeColor.opacity(0.3)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 460)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear],
                                         startPoint: .top, endPoint: .bottom))
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(LineupPresentationStyle.text)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .padding(.leading, 16).padding(.top, 6)
        }
        .foregroundStyle(LineupPresentationStyle.text)
        .task(id: library.eventChannelsInputs) { await findChannels() }
        .task { await loadForm() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 18) {
            Text(competitionName)
                .font(.inter(14, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                .lineLimit(1).frame(maxWidth: .infinity)
            if current.isEvent {
                VStack(spacing: 10) {
                    Text(current.matchupLine).font(.inter(26, .heavy)).multilineTextAlignment(.center)
                    startTime
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    side(name: current.awayTeam, logo: current.awayLogo, abbreviation: current.awayAbbreviation,
                         rank: current.awayRank, record: current.awayRecord)
                    startTime.padding(.top, 14)
                    side(name: current.homeTeam, logo: current.homeLogo, abbreviation: current.homeAbbreviation,
                         rank: current.homeRank, record: current.homeRecord)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 62)
    }

    private var competitionName: String {
        current.competition?.name ?? current.league.fullName
    }

    private func side(name: String, logo: String, abbreviation: String, rank: Int?, record: String?) -> some View {
        VStack(spacing: 10) {
            TeamBadge(url: logo, fallback: abbreviation, size: 72)
            VStack(spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let rank, rank <= 25 {
                        Text("\(rank)").font(.inter(12, .bold)).foregroundStyle(LineupPresentationStyle.secondary)
                    }
                    Text(name).font(.inter(16, .bold)).lineLimit(2).multilineTextAlignment(.center)
                        .minimumScaleFactor(0.85)
                }
                if let record, !record.isEmpty {
                    Text(record).font(.inter(13, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var startTime: some View {
        VStack(spacing: 4) {
            Text(current.start.formatted(date: .omitted, time: .shortened))
                .font(.interDigits(30, .heavy)).lineLimit(1).minimumScaleFactor(0.6)
            Text(Self.day(of: current.start))
                .font(.inter(13, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// "Today", "Tomorrow", or the day: "Friday", "Nov 28".
    static func day(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return days > 0 && days < 7 ? date.formatted(.dateTime.weekday(.wide))
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            detail("calendar", current.start.formatted(.dateTime.weekday(.wide).month(.wide).day())
                    + " · " + current.start.formatted(date: .omitted, time: .shortened))
            if let venue = place { detail("mappin.and.ellipse", venue) }
            if !current.broadcast.isEmpty { detail("tv", current.broadcast) }
        }
        .padding(.horizontal, 20)
    }

    /// The venue, and its city when the feed gives one.
    private var place: String? {
        let parts = [current.venue, current.location].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func detail(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LineupPresentationStyle.secondary).frame(width: 22)
            Text(text).font(.inter(16)).lineLimit(2)
        }
    }

    // MARK: Where to watch

    private var whereToWatch: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where to Watch").font(.inter(24, .heavy)).padding(.horizontal, 20)
            if channels.isEmpty && networkChannels.isEmpty {
                HStack(spacing: 10) {
                    if findingChannels { ProgressView() }
                    Text(findingChannels ? "Looking through your playlists…"
                         : "Not in your playlists or guide yet. Channels usually show up closer to the start.")
                        .font(.inter(14)).foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
                .padding(.horizontal, 16)
            }
            if !channels.isEmpty {
                channelList(channels, fallback: current.matchupLine)
            }
            if !networkChannels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On \(current.broadcast)").font(.inter(17, .bold))
                    Text("Your guide hasn't listed it on these yet, but \(current.broadcast) is showing it.")
                        .font(.inter(13)).foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20).padding(.top, channels.isEmpty ? 0 : 8)
                channelList(networkChannels, fallback: "On \(current.broadcast) at "
                            + current.start.formatted(date: .omitted, time: .shortened))
            }
            if findingChannels && !(channels.isEmpty && networkChannels.isEmpty) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking your other playlists…").font(.inter(13))
                        .foregroundStyle(LineupPresentationStyle.secondary)
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func channelList(_ list: [MobileProviderChannel], fallback: String) -> some View {
        VStack(spacing: 10) {
            ForEach(list) { channel in
                MobileEventChannelRow(source: channel, isPlaying: false, live: false, fallback: fallback) {
                    onPick(channel)
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Reminder

    private var remindButton: some View {
        let on = reminders.reminds(current)
        return Button {
            reminders.toggleGame(current)
        } label: {
            Label(on ? "Reminder Set" : "Remind Me", systemImage: on ? "bell.fill" : "bell")
                .font(.inter(17, .bold))
                .foregroundStyle(on ? LineupStyle.onHighlight : LineupPresentationStyle.text)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background {
                    if on { Capsule().fill(LineupStyle.highlight) }
                    else { Capsule().fill(LineupPresentationStyle.card) }
                }
                .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0 : 0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.18), value: on)
        .accessibilityHint(on ? "Removes the reminder" : "Notifies you when the game starts")
    }

    // MARK: Form

    @ViewBuilder
    private var form: some View {
        if awayForm?.isEmpty == false || homeForm?.isEmpty == false {
            VStack(alignment: .leading, spacing: 12) {
                Text("Form").font(.inter(24, .heavy)).padding(.horizontal, 20)
                VStack(spacing: 10) {
                    formRow(current.awayTeam, logo: current.awayLogo, abbreviation: current.awayAbbreviation,
                            color: awayColor, results: awayForm)
                    formRow(current.homeTeam, logo: current.homeLogo, abbreviation: current.homeAbbreviation,
                            color: homeColor, results: homeForm)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func formRow(_ name: String, logo: String, abbreviation: String, color: Color,
                         results: [TeamPageGame.Outcome]?) -> some View {
        HStack(spacing: 12) {
            TeamBadge(url: logo, fallback: abbreviation, size: 36)
            Text(name).font(.inter(16, .bold)).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                ForEach(Array((results ?? []).enumerated()), id: \.offset) { _, outcome in
                    Text(outcome.rawValue)
                        .font(.inter(13, .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Self.color(of: outcome).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last \(results?.count ?? 0): "
                + (results ?? []).map(\.rawValue).joined(separator: ", "))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        // As a game's card: the team's colour faint across the app's card.
        .background(LinearGradient(colors: [color.opacity(0.19), color.opacity(0.06)],
                                   startPoint: .leading, endPoint: .trailing), in: LineupPanelStyle.shape)
        .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
        .overlay(LineupPanelStyle.shape.strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
    }

    private static func color(of outcome: TeamPageGame.Outcome) -> Color {
        switch outcome {
        case .win: LineupStyle.positive
        case .loss: LineupStyle.live
        case .tie: Color.gray
        }
    }

    // MARK: Loading

    /// The game's channels in every enabled playlist, the playing one's
    /// first: those its guide confirms, as the Channels sheet finds them, and
    /// apart from those, each playlist's feeds of the network it is on.
    private func findChannels() async {
        let root = library.providerRoot
        let event = current
        let profiles = root.enabledProfiles
        let board = root.eventChannelTournamentBoard
        let order = Dictionary(uniqueKeysWithValues: profiles.enumerated().map { ($1.id, $0) })
        func ordered(_ list: [MobileProviderChannel]) -> [MobileProviderChannel] {
            list.enumerated().sorted {
                let left = order[$0.element.profile.id] ?? Int.max
                let right = order[$1.element.profile.id] ?? Int.max
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
        }
        findingChannels = true
        var confirmed: [MobileProviderChannel] = []
        var network: [MobileProviderChannel] = []
        if let active = root.activeProfile, order[active.id] != nil {
            let matched = await root.eventChannels(for: event)
            guard !Task.isCancelled else { return }
            let streams = root.streams, categories = root.categories, programs = root.programsByChannel
            let taken = Set(matched.map(\.id))
            let fallback = await Task.detached(priority: .userInitiated) {
                NetworkChannelFallback.channels(for: event, streams: streams, categories: categories,
                                                programs: programs, excluding: taken)
            }.value
            guard !Task.isCancelled else { return }
            confirmed += matched.map { MobileProviderChannel(profile: active, channel: $0) }
            network += fallback.map { MobileProviderChannel(profile: active, channel: $0) }
            channels = ordered(confirmed)
            networkChannels = ordered(network)
        }
        let others = profiles.filter { $0.id != root.activeProfile?.id }
            .map { ($0, KeychainStore.password(profileID: $0.id)) }
        await withTaskGroup(of: (UUID, [LiveEventChannel], [LiveEventChannel]).self) { group in
            for (profile, secret) in others {
                group.addTask { await Self.channels(in: profile, secret: secret, game: event, board: board) }
            }
            for await (id, matched, fallback) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                guard let profile = profiles.first(where: { $0.id == id }) else { continue }
                confirmed += matched.map { MobileProviderChannel(profile: profile, channel: $0) }
                network += fallback.map { MobileProviderChannel(profile: profile, channel: $0) }
                channels = ordered(confirmed)
                networkChannels = ordered(network)
            }
        }
        guard !Task.isCancelled else { return }
        findingChannels = false
    }

    /// One playlist other than the playing one, from its saved copy: the
    /// channels its guide confirms, and its feeds of the game's network.
    nonisolated private static func channels(in profile: XtreamProfile, secret: String?, game: SportsGame,
                                             board: [[String]]) async -> (UUID, [LiveEventChannel], [LiveEventChannel]) {
        guard let secret,
              let snapshot = try? await MobileProviderCatalog.shared.snapshot(for: profile, secret: secret) else {
            return (profile.id, [], [])
        }
        return await Task.detached(priority: .userInitiated) {
            let matched = snapshot.matching(game, board: board)
            let fallback = NetworkChannelFallback.channels(for: game, streams: snapshot.streams,
                categories: snapshot.categories, programs: snapshot.programs, excluding: Set(matched.map(\.id)))
            return (profile.id, matched, fallback)
        }.value
    }

    /// Each side's last five results, oldest first, from its ESPN schedule.
    private func loadForm() async {
        guard !current.isEvent else { return }
        async let away = Self.form(path: formPath(away: true))
        async let home = Self.form(path: formPath(away: false))
        let (a, h) = await (away, home)
        awayForm = a
        homeForm = h
    }

    /// A side's ESPN page: by the id the game carries, or else by the team
    /// directory, as the side's own team page is found.
    private func formPath(away: Bool) -> TeamPagePath? {
        let game = current
        if let path = MobileTeamPageTarget.path(league: game.league, teamID: away ? game.awayTeamID : game.homeTeamID,
                                                competition: game.competition?.id) {
            return path
        }
        let abbreviation = (away ? game.awayAbbreviation : game.homeAbbreviation).uppercased()
        return library.followableSides(of: game).first { $0.team.uppercased() == abbreviation }
            .flatMap { MobileTeamPageTarget(side: $0, competition: game.competition?.id)?.path }
    }

    private static func form(path: TeamPagePath?) async -> [TeamPageGame.Outcome]? {
        guard let path, let games = await MobileTeamPageClient.shared.schedule(path) else { return nil }
        return Self.lastResults(games)
    }

    /// The last five games played, oldest first.
    static func lastResults(_ games: [TeamPageGame], count: Int = 5) -> [TeamPageGame.Outcome] {
        Array(games.filter(\.isFinished).sorted { $0.date < $1.date }.compactMap(\.outcome).suffix(count))
    }
}
