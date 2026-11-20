#if os(tvOS)
import SwiftUI

/// What a game's hold menu can open beyond the game itself: the channels
/// verified to carry it, the game from its start on one that keeps a
/// recording, and either side's page. The Sports tab hands these down and
/// presents each one, as it presents the channel picker.
struct LiveGameActions {
    var channels: (SportsGame) -> Void
    var catchUp: (SportsGame) -> Void
    var teamPage: (MobileTeamPageTarget) -> Void
    /// My Teams' NFL games, recorded.
    var replays: () -> Void

    /// Channels and Catch Up, while the game is on. Catch Up is offered
    /// wherever the provider can keep recordings; whether a channel carrying
    /// this game keeps one is found out when it is chosen.
    @MainActor
    func liveItems(for game: SportsGame, library: SportsLibrary) -> [TVChoice] {
        guard game.isLive else { return [] }
        var items = [TVChoice("Channels", symbol: "tv") { channels(game) }]
        if let profile = library.activeProfile, !profile.isPlaylist {
            items.append(TVChoice("Catch Up", symbol: "clock.arrow.circlepath") { catchUp(game) })
        }
        return items
    }

    /// Each side's page: its schedule, standing, roster, injuries, news.
    @MainActor
    func teamItems(for game: SportsGame, library: SportsLibrary) -> [TVChoice] {
        library.followableSides(of: game).compactMap { side in
            MobileTeamPageTarget(side: side, competition: game.competition?.id).map { target in
                TVChoice(side.name, symbol: "person.2", id: "team-\(side.id)") { teamPage(target) }
            }
        }
    }
}

private struct LiveGameActionsKey: EnvironmentKey {
    static let defaultValue: LiveGameActions? = nil
}

extension EnvironmentValues {
    var liveGameActions: LiveGameActions? {
        get { self[LiveGameActionsKey.self] }
        set { self[LiveGameActionsKey.self] = newValue }
    }
}

// MARK: - Channels

struct TVEventChannelsPage: Identifiable {
    let game: SportsGame
    let pregame: Bool
    var id: String { game.id }
}

/// Pregame and the live Channels action share the same Where to Watch results.
struct TVEventChannelsScreen: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var reminders: GameReminders
    let page: TVEventChannelsPage
    let onPick: (MobileProviderPlaybackSource, SportsGame) -> Void
    let onSearch: () -> Void

    @State private var results = MobileGameChannelResults()
    @State private var reload = 0
    @State private var selected: MobileProviderChannel.ID?
    @State private var pickTask: Task<Void, Never>?
    @State private var pickFailed = false

    private var current: SportsGame {
        library.gamesByLeague[page.game.league]?.first { $0.id == page.game.id } ?? page.game
    }

    var body: some View {
        let inputs = library.tvEventChannelsInputs(for: current)
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 20) {
                if page.pregame {
                    pregameDetails
                } else {
                    LineupIconTile(symbol: "tv", size: 72)
                    Text(current.matchupLine).font(.inter(36, .bold)).lineLimit(3)
                }
                TVServerLibraryChip(title: "Choose Another Channel", symbol: "magnifyingglass",
                                    chosen: false, action: onSearch)
            }
            .frame(width: 550, alignment: .leading)
            .lineupFocusRegion()
            list.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90).padding(.top, 70)
        .foregroundStyle(LineupPresentationStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .task(id: inputs + [AnyHashable(reload)]) {
            if results.confirmed.isEmpty && results.network.isEmpty { results.finished = false }
            await MobileGameChannels.find(in: library, game: current) { found in
                guard !Task.isCancelled, inputs == library.tvEventChannelsInputs(for: current) else { return }
                results = found
            }
        }
        .onExitCommand { dismiss() }
        .onDisappear { pickTask?.cancel() }
    }

    private var pregameDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            SportsMark(league: current.isNFLRedZone ? .nfl : current.league,
                       competition: current.league == .soccer ? current.competition : nil, size: 58)
                .accessibilityLabel(current.competition?.name ?? current.league.fullName)
            if !current.isEvent {
                HStack(alignment: .top, spacing: 14) {
                    team(current.awayTeam, logo: current.awayLogo, abbreviation: current.awayAbbreviation,
                         rank: current.awayRank, record: current.awayRecord)
                    Text(current.sidesWord).font(.inter(22, .semibold))
                        .foregroundStyle(LineupPresentationStyle.secondary).padding(.top, 34)
                    team(current.homeTeam, logo: current.homeLogo, abbreviation: current.homeAbbreviation,
                         rank: current.homeRank, record: current.homeRecord)
                }
            } else {
                Text(current.matchupLine).font(.inter(40, .bold)).lineLimit(3)
            }
            Label(current.start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()),
                  systemImage: "calendar")
            let place = [current.venue, current.location].compactMap { $0 }.filter { !$0.isEmpty }
            if !place.isEmpty { Label(place.joined(separator: ", "), systemImage: "mappin.and.ellipse") }
            if !current.broadcast.isEmpty { Label(current.broadcast, systemImage: "tv") }
            if current.isUpcoming {
                let on = reminders.reminds(current)
                TVServerLibraryChip(title: on ? "Reminder Set" : "Remind Me",
                                    symbol: on ? "bell.fill" : "bell", chosen: on) {
                    reminders.toggleGame(current)
                }
            }
        }
        .font(.inter(22))
    }

    private func team(_ name: String, logo: String, abbreviation: String, rank: Int?, record: String?) -> some View {
        VStack(spacing: 8) {
            TeamBadge(url: logo, fallback: abbreviation, size: 92)
            Text(rank.map { $0 <= 25 ? "\($0) \(name)" : name } ?? name)
                .font(.inter(26, .bold)).multilineTextAlignment(.center).lineLimit(2)
            if let record, !record.isEmpty {
                Text(record).font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("Where to Watch").font(.inter(42, .bold)).accessibilityAddTraits(.isHeader)
                if !results.confirmed.isEmpty {
                    Text("Confirmed Channels").font(.inter(22, .bold))
                    rows(results.confirmed, confirmed: true)
                }
                if !results.network.isEmpty {
                    Text("On \(current.broadcast)").font(.inter(22, .bold)).padding(.top, 10)
                    Text("Your guide hasn't listed this game on these feeds yet.")
                        .font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary)
                    rows(results.network, confirmed: false)
                }
                if !results.finished {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(results.confirmed.isEmpty && results.network.isEmpty
                             ? "Looking through your playlists…" : "Checking your other playlists…")
                            .font(.inter(21)).foregroundStyle(LineupPresentationStyle.secondary)
                    }
                } else if results.confirmed.isEmpty && results.network.isEmpty {
                    Text("No matching channels").font(.inter(26, .semibold))
                    Text(current.isLive ? "Search your provider with Choose Another Channel."
                                        : "Channels usually show up closer to the start.")
                        .font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary)
                }
                ForEach(results.issues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary)
                }
                if pickFailed {
                    Text("This feed is unavailable. Try another channel.")
                        .font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).padding(.bottom, 70)
        }
        .scrollIndicators(.hidden)
        .lineupFocusRegion()
    }

    private func rows(_ entries: [MobileProviderChannel], confirmed: Bool) -> some View {
        ForEach(entries) { entry in
            TVSelectable(scale: LineupStyle.cardLift, fillRadius: LineupPanelStyle.radius,
                         action: { pick(entry, confirmed: confirmed) }) {
                TVEventChannelRow(channel: entry.channel, provider: entry.profile.name,
                                  opening: selected == entry.id, live: current.isLive,
                                  fallback: confirmed ? current.matchupLine : "On \(current.broadcast)")
            }
        }
    }

    private func pick(_ entry: MobileProviderChannel, confirmed: Bool) {
        guard selected == nil else { return }
        selected = entry.id
        pickFailed = false
        pickTask = Task { @MainActor in
            let source = await library.prepareEventChannel(entry, for: current, confirmed: confirmed)
            guard !Task.isCancelled else { return }
            selected = nil
            if let source {
                onPick(source, current)
            } else {
                pickFailed = true
                reload += 1
            }
        }
    }
}

private struct TVEventChannelRow: View {
    let channel: LiveEventChannel
    let provider: String
    let opening: Bool
    let live: Bool
    let fallback: String

    var body: some View {
        HStack(spacing: 20) {
            TeamBadge(url: channel.stream.streamIcon ?? "", fallback: "TV", size: 64, tight: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(channel.stream.name).font(.inter(23, .bold)).lineLimit(2)
                Text(channel.program?.title ?? fallback).font(.inter(18))
                    .foregroundStyle(LineupPresentationStyle.secondary).lineLimit(2)
                HStack(spacing: 12) {
                    Text(provider).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                    if live {
                        HStack(spacing: 6) {
                            Circle().fill(LineupStyle.liveStatus).frame(width: 8, height: 8)
                            Text("Live now").foregroundStyle(LineupStyle.liveStatus)
                        }
                    }
                    if let label = channel.quality.label {
                        Text("Provider \(label)").foregroundStyle(LineupPresentationStyle.secondary)
                            .accessibilityLabel("Provider quality: \(label)")
                    }
                }
                .font(.inter(17, .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if opening { ProgressView() }
                else { Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)) }
            }
            .foregroundStyle(LineupStyle.onHighlight)
            .frame(width: 58, height: 58).background(LineupStyle.highlight, in: Circle())
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Play this event on this channel")
    }
}

// MARK: - Game Replays

/// My Teams' NFL games the provider recorded, newest first, as the phone's
/// Game Replays lists them: only archive-enabled NFL channels are asked,
/// and only a listing that names both sides of a matchup with a followed
/// team counts. The same game on several channels is one row, which asks
/// for the channel.
struct TVGameReplaysScreen: View {
    @Environment(SportsLibrary.self) private var library
    @StateObject private var store = MobileGameReplayStore()
    let onSelect: (MobileGameReplayRecording) -> Void
    @State private var refresh = 0
    @State private var choosing: MobileGameReplay?

    private static let teams = SportsTeamDirectory.bundled.teams.filter { $0.league == .nfl }
        .map { MobileGameReplayPolicy.Team($0.followedTeam) }

    private var request: MobileGameReplayStore.Request {
        .init(profileID: library.activeProfile?.id, playlist: library.activeProfile?.isPlaylist ?? false,
              refreshed: library.lastRefreshedAt, channelCount: library.streams.count,
              followedIDs: library.followedTeams.teams.filter { $0.league == "NFL" }.map(\.id).sorted(),
              enabled: true, refresh: refresh)
    }

    var body: some View {
        let request = request
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                LineupIconTile(symbol: "clock.arrow.circlepath", size: 72)
                Text("Game Replays").font(.inter(44, .bold)).padding(.top, 26)
                Text("Your NFL teams' games your provider recorded, from kickoff.")
                    .font(.inter(21)).foregroundStyle(LineupPresentationStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                    store.clearCache()
                    refresh += 1
                }) {
                    TVReplayRefreshLabel(loading: store.loading)
                }
                .padding(.top, 30)
                .accessibilityLabel("Refresh game replays")
            }
            .frame(width: 520, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 60)) { clock in
                content(replays(at: clock.date, request: request), request: request)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90).padding(.top, 70)
        .foregroundStyle(LineupPresentationStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .task(id: request) {
            await store.load(request, streams: library.streams, categories: library.categories, teams: Self.teams) { stream in
                guard let profileID = request.profileID else { throw CancellationError() }
                return try await library.gameReplayProgrammes(for: stream, profileID: profileID)
            }
        }
        .onDisappear { store.cancel() }
        .tvChoices("Replay Channels", symbol: "tv",
                   isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                   message: choosing?.title) {
            guard let replay = choosing else { return [] }
            return replay.recordings.map { recording in
                TVChoice(recording.stream.name, symbol: "play.fill", id: recording.id) { onSelect(recording) }
            }
        }
    }

    /// The replays as of now: a recording past the provider's keeping goes
    /// on the minute, without asking again.
    private func replays(at now: Date, request: MobileGameReplayStore.Request) -> [MobileGameReplay] {
        guard store.request == request else { return [] }
        return store.replays.compactMap { replay in
            let recordings = replay.recordings.filter {
                MobileGameReplayPolicy.available($0.program, stream: $0.stream, now: now)
            }
            return recordings.isEmpty ? nil : MobileGameReplay(teams: replay.teams, recordings: recordings)
        }
    }

    @ViewBuilder
    private func content(_ replays: [MobileGameReplay], request: MobileGameReplayStore.Request) -> some View {
        if !replays.isEmpty {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(replays) { replay in
                        TVSelectable(scale: LineupStyle.cardLift, fillRadius: LineupPanelStyle.radius,
                                     action: { select(replay, request: request) },
                                     requestInitialFocus: replay.id == replays.first?.id) {
                            TVReplayRow(replay: replay)
                        }
                        .accessibilityLabel("Replay: \(replay.title), recorded \(replay.start.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if store.loading {
                        HStack(spacing: 14) {
                            ProgressView().tint(LineupPresentationStyle.text)
                            Text("Checking more channels…").font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary)
                        }
                        .padding(.vertical, 18)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10).padding(.bottom, 70)
            }
            .scrollIndicators(.hidden)
        } else if request.followedIDs.isEmpty {
            message("Follow an NFL team to see its game replays here.", symbol: "star")
        } else if request.profileID == nil || request.playlist {
            message("Game replays need a provider connection with Xtream catch-up.", symbol: "tv.slash")
        } else if store.request != request || store.loading {
            VStack(spacing: 18) {
                ProgressView().tint(LineupPresentationStyle.text)
                Text("Checking recorded games…").font(.inter(21)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.failedChannels > 0 {
            message("Some replay channels couldn't be checked. Select Refresh to try again.", symbol: "wifi.exclamationmark")
        } else {
            message("No recorded NFL games are available for your teams right now.", symbol: "clock.arrow.circlepath")
        }
    }

    private func select(_ replay: MobileGameReplay, request: MobileGameReplayStore.Request) {
        guard store.request == request else { return }
        if replay.recordings.count == 1, let recording = replay.recordings.first {
            onSelect(recording)
        } else {
            choosing = replay
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(LineupPresentationStyle.secondary)
            Text(text).font(.inter(22)).foregroundStyle(LineupPresentationStyle.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TVReplayRow: View {
    let replay: MobileGameReplay

    var body: some View {
        HStack(spacing: 24) {
            SportsMark(league: .nfl, size: 54)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(replay.teams) { team in
                    HStack(spacing: 14) {
                        TeamBadge(url: team.logo, fallback: team.abbreviation, size: 40, tight: true)
                        Text(team.name).font(.inter(23, .semibold))
                    }
                }
                Text(replay.start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.inter(17, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(LineupStyle.onHighlight)
                    .frame(width: 58, height: 58).background(LineupStyle.highlight, in: Circle())
                if replay.recordings.count > 1 {
                    Text("\(replay.recordings.count) channels").font(.inter(16, .medium))
                        .foregroundStyle(LineupPresentationStyle.secondary)
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
    }
}

private struct TVReplayRefreshLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let loading: Bool

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise").font(.system(size: 20, weight: .bold))
            Text(loading ? "Checking…" : "Refresh").font(.inter(21, .semibold))
        }
        .padding(.horizontal, 24).frame(height: 58)
        .background(LineupPresentationStyle.row, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// In My Teams, while an NFL team is followed: the way to Game Replays.
struct TVGameReplaysEntry: View {
    let action: () -> Void

    var body: some View {
        TVSelectable(scale: LineupStyle.cardLift, drawsFocusChrome: false, action: action) {
            TVGameReplaysEntryLabel()
        }
        .accessibilityLabel("Game Replays")
    }
}

private struct TVGameReplaysEntryLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 14) {
            LineupIconTile(symbol: "clock.arrow.circlepath", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Game Replays").font(.inter(19, .semibold))
                Text("Your NFL teams' recorded games").font(.inter(15)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .bold))
                .foregroundStyle(LineupPresentationStyle.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPresentationStyle.row, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}
#endif
