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
    func liveItems(for game: SportsGame, library: SportsLibrary) -> [TVChoice] {
        guard game.isLive else { return [] }
        var items = [TVChoice("Channels", symbol: "tv") { channels(game) }]
        if let profile = library.activeProfile, !profile.isPlaylist {
            items.append(TVChoice("Catch Up", symbol: "clock.arrow.circlepath") { catchUp(game) })
        }
        return items
    }

    /// Each side's page: its schedule, standing, roster, injuries, news.
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

/// The channels Lineup has verified carry a game, each with what its guide
/// says is on and the quality the provider names. The broad picker, Choose
/// Another Channel, stays separate for feeds whose guide is missing or
/// named differently. No stream is opened to fill the list.
struct TVEventChannelsScreen: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let game: SportsGame
    let playingID: Int?
    let onPick: (XtreamStream) -> Void
    @State private var channels: [LiveEventChannel] = []
    @State private var loading = true
    @State private var waiting = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var openedProfileID: UUID?

    private var current: SportsGame { library.gamesByLeague[game.league]?.first { $0.id == game.id } ?? game }

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                LineupIconTile(symbol: "tv", size: 72)
                Text("Channels").font(.inter(44, .bold)).padding(.top, 26)
                Text(current.matchupLine).font(.inter(23, .semibold)).foregroundStyle(LineupStyle.secondary)
                    .lineLimit(3).padding(.top, 8)
                Text("Every channel here is one Lineup checked against the guide for this game. To search the provider yourself, hold Select on the game and choose Choose Another Channel.")
                    .font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 22)
            }
            .frame(width: 520, alignment: .leading)
            list.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90).padding(.top, 70)
        .foregroundStyle(LineupStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.background.ignoresSafeArea())
        .onAppear {
            openedProfileID = library.activeProfile?.id
            reload()
        }
        .onChange(of: library.eventChannelsInputs) { reload() }
        .onDisappear { reloadTask?.cancel() }
    }

    @ViewBuilder
    private var list: some View {
        if loading || waiting {
            VStack(spacing: 18) {
                ProgressView().tint(LineupStyle.text)
                Text(waiting ? "Matching event channels…" : "Finding channels…")
                    .font(.inter(21)).foregroundStyle(LineupPanelStyle.quiet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if channels.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "tv.slash").font(.system(size: 44)).foregroundStyle(LineupPanelStyle.quiet)
                Text("No matching channels").font(.inter(26, .semibold))
                Text("No channel could be verified for this event. Choose Another Channel, in the game's menu, searches your provider.")
                    .font(.inter(19)).foregroundStyle(LineupStyle.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 620)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("\(channels.count) \(channels.count == 1 ? "CHANNEL" : "CHANNELS")")
                        .font(.inter(17, .heavy)).tracking(1).foregroundStyle(LineupPanelStyle.caption)
                    ForEach(channels) { channel in
                        TVSelectable(scale: LineupStyle.cardLift, fillRadius: LineupPanelStyle.radius,
                                     action: { pick(channel) },
                                     requestInitialFocus: channel.id == channels.first?.id) {
                            TVEventChannelRow(channel: channel, isPlaying: channel.id == playingID,
                                              live: current.isLive, fallback: current.matchupLine)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10).padding(.bottom, 70)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// A row can outlive its guide evidence: checked again on Select, before
    /// anything is played or remembered.
    private func pick(_ entry: LiveEventChannel) {
        guard library.activeProfile?.id == openedProfileID else { dismiss(); return }
        guard current.isLive || current.isUpcoming,
              let stream = library.stream(withID: entry.id),
              stream.name == entry.stream.name, stream.epgChannelID == entry.stream.epgChannelID,
              library.isEventChannel(stream, verifiedFor: current) else { reload(); return }
        onPick(stream)
    }

    private func reload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard library.activeProfile?.id == openedProfileID else { dismiss(); return }
            let event = current
            waiting = !library.eventChannelsReady(for: event) && library.channelsAreSyncing
            loading = true
            let result = await library.eventChannels(for: event)
            guard !Task.isCancelled else { return }
            channels = result
            loading = false
        }
    }
}

private struct TVEventChannelRow: View {
    let channel: LiveEventChannel
    let isPlaying: Bool
    let live: Bool
    let fallback: String

    var body: some View {
        HStack(spacing: 20) {
            TeamBadge(url: channel.stream.streamIcon ?? "", fallback: "TV", size: 64, tight: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(channel.stream.name).font(.inter(23, .bold)).lineLimit(2)
                Text(channel.program?.title ?? fallback).font(.inter(18))
                    .foregroundStyle(LineupPanelStyle.quiet).lineLimit(2)
                HStack(spacing: 12) {
                    if live {
                        HStack(spacing: 6) {
                            Circle().fill(LineupStyle.liveStatus).frame(width: 8, height: 8)
                            Text("Live now").foregroundStyle(LineupStyle.liveStatus)
                        }
                    }
                    if let label = channel.quality.label {
                        Text("Provider \(label)").foregroundStyle(LineupStyle.secondary)
                            .accessibilityLabel("Provider quality: \(label)")
                    }
                }
                .font(.inter(17, .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(LineupStyle.onHighlight)
                .frame(width: 58, height: 58).background(LineupStyle.highlight, in: Circle())
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isPlaying ? "Playing now" : "Play this event on this channel")
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
                    .font(.inter(21)).foregroundStyle(LineupStyle.secondary)
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
        .foregroundStyle(LineupStyle.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.background.ignoresSafeArea())
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
                            ProgressView().tint(LineupStyle.text)
                            Text("Checking more channels…").font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet)
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
                ProgressView().tint(LineupStyle.text)
                Text("Checking recorded games…").font(.inter(21)).foregroundStyle(LineupPanelStyle.quiet)
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
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(LineupPanelStyle.quiet)
            Text(text).font(.inter(22)).foregroundStyle(LineupStyle.secondary)
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
                    .font(.inter(17, .medium)).foregroundStyle(LineupPanelStyle.quiet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(LineupStyle.onHighlight)
                    .frame(width: 58, height: 58).background(LineupStyle.highlight, in: Circle())
                if replay.recordings.count > 1 {
                    Text("\(replay.recordings.count) channels").font(.inter(16, .medium))
                        .foregroundStyle(LineupPanelStyle.quiet)
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
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
        .background(LineupPanelStyle.well, in: shape)
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
                Text("Your NFL teams' recorded games").font(.inter(15)).foregroundStyle(LineupPanelStyle.quiet)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .bold))
                .foregroundStyle(LineupPanelStyle.quiet)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupStyle.raised, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}
#endif
