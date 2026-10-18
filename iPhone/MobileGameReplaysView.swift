import SwiftUI

struct MobileGameReplaysSection: View {
    @Environment(\.mobileHoldMenu) private var menu
    @ObservedObject var library: SportsLibrary
    @ObservedObject var store: MobileGameReplayStore
    let enabled: Bool
    let onSelect: (MobileGameReplaySelection) -> Void
    @State private var refresh = 0
    @State private var choosing = false

    private static let teams = SportsTeamDirectory.bundled.teams.filter { $0.league == .nfl }
        .map { MobileGameReplayPolicy.Team($0.followedTeam) }

    private var request: MobileGameReplayStore.Request {
        .init(profileID: library.activeProfile?.id, playlist: library.activeProfile?.isPlaylist ?? false,
              refreshed: library.lastRefreshedAt, channelCount: library.streams.count,
              followedIDs: library.followedTeams.teams.filter { $0.league == "NFL" }.map(\.id).sorted(),
              enabled: enabled, refresh: refresh)
    }

    var body: some View {
        let request = request
        LineupPanel(title: "Game Replays", systemImage: "clock.arrow.circlepath", padded: false) {
            Button {
                store.clearCache()
                refresh += 1
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.plain).foregroundStyle(LineupStyle.highlight)
            .disabled(!enabled || store.loading).accessibilityLabel("Refresh game replays")
        } content: {
            TimelineView(.periodic(from: .now, by: 60)) { clock in
                let replays = store.request == request ? store.replays.compactMap { replay -> MobileGameReplay? in
                    let recordings = replay.recordings.filter {
                        MobileGameReplayPolicy.available($0.program, stream: $0.stream, now: clock.date)
                    }
                    return recordings.isEmpty ? nil : MobileGameReplay(teams: replay.teams, recordings: recordings)
                } : []
                replayContent(replays, request: request)
            }
        }
        .task(id: request) {
            await store.load(request, streams: library.streams, categories: library.categories, teams: Self.teams) { stream in
                guard let profileID = request.profileID else { throw CancellationError() }
                return try await library.gameReplayProgrammes(for: stream, profileID: profileID)
            }
        }
        .onDisappear { store.cancel(); dismissChoices() }
        .onChange(of: request) { _, _ in dismissChoices() }
    }

    @ViewBuilder private func replayContent(_ replays: [MobileGameReplay], request: MobileGameReplayStore.Request) -> some View {
        VStack(spacing: 0) {
            if !replays.isEmpty {
                ForEach(Array(replays.enumerated()), id: \.element.id) { index, replay in
                    if index > 0 { Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.horizontal, LineupPanelStyle.inset) }
                    Button {
                        guard let profile = request.profileID, store.request == request else { return }
                        if replay.recordings.count == 1, let recording = replay.recordings.first {
                            onSelect(MobileGameReplaySelection(profileID: profile, recording: recording))
                        } else { chooseChannel(replay, request: request, profile: profile) }
                    } label: { replayRow(replay) }
                    .buttonStyle(MobileCardButtonStyle())
                    .accessibilityLabel("Replay: \(replay.title), recorded \(replay.start.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            if request.followedIDs.isEmpty {
                message("Follow an NFL team to see its available game replays here.")
            } else if request.profileID == nil || request.playlist {
                message("Game replays need a provider connection with Xtream catch-up support.")
            } else if store.request != request || store.loading {
                HStack(spacing: 10) { ProgressView(); Text("Checking recorded games…").font(.inter(.caption)) }
                    .foregroundStyle(LineupPanelStyle.quiet).padding(18)
            } else if store.failedChannels > 0 {
                message("Some replay channels couldn't be checked. Tap refresh to try again.")
            } else if replays.isEmpty {
                message("No recorded NFL games are available for your followed teams right now.")
            }
        }
    }

    private func chooseChannel(_ replay: MobileGameReplay, request: MobileGameReplayStore.Request, profile: UUID) {
        guard let menu else { return }
        choosing = true
        // Use the app's root menu host so a long replay list cannot put the
        // choices below the viewport or behind the navigation bar.
        menu.present("Replay Channels", symbol: "tv", message: replay.title,
            items: replay.recordings.map { recording in
                MobileMenuItem(recording.stream.name, symbol: "play.fill", id: recording.id) {
                    guard store.request == request, library.activeProfile?.id == profile else { return }
                    choosing = false
                    onSelect(MobileGameReplaySelection(profileID: profile, recording: recording))
                }
            })
    }

    private func dismissChoices() {
        if choosing, menu?.request?.title == "Replay Channels" { menu?.request = nil }
        choosing = false
    }

    private func replayRow(_ replay: MobileGameReplay) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(replay.teams) { team in
                    HStack(spacing: 9) {
                        TeamBadge(url: team.logo, fallback: team.abbreviation, size: 28, tight: true)
                        Text(team.name).font(.inter(.subheadline, .semibold)).multilineTextAlignment(.leading)
                    }
                }
                Text(replay.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                MobileLeagueLogo(league: .nfl, size: 28)
                Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(LineupStyle.highlight)
                if replay.recordings.count > 1 {
                    Text("\(replay.recordings.count) channels").font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet)
                }
            }
        }
        .foregroundStyle(LineupStyle.text).padding(.horizontal, LineupPanelStyle.inset).padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.inter(.caption)).foregroundStyle(LineupPanelStyle.quiet)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
    }
}

struct MobileGameReplayPlayer: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MobilePlaybackController()
    @State private var retry = UUID()
    let selection: MobileGameReplaySelection

    var body: some View {
        GeometryReader { viewport in
            MobileGuidePlayer(controller: controller, stream: selection.recording.stream,
                program: nil, expanded: true, showsMetadata: true,
                videoHeight: MobilePlayerLayout.fullscreenHeight(containerHeight: viewport.size.height,
                    safeAreaTop: viewport.safeAreaInsets.top, safeAreaBottom: viewport.safeAreaInsets.bottom),
                screenInsets: viewport.safeAreaInsets, onClose: { dismiss() }, onExpand: nil, onRetry: { retry = UUID() })
                .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea()).statusBarHidden(true).persistentSystemOverlays(.hidden)
        .modifier(MobileDismissGesture(enabled: true, onBeginExit: { controller.freezePictureForExit() }) { dismiss() })
        .task(id: retry) { await open() }
        .onDisappear { controller.shutdown() }
        .onChange(of: scenePhase) { _, phase in controller.handleScenePhase(active: phase == .active) }
        .onChange(of: library.activeProfile?.id) { _, profile in if profile != selection.profileID { dismiss() } }
    }

    private func open() async {
        controller.stop()
        controller.error = nil
        controller.loading = true
        let recording = selection.recording
        guard library.activeProfile?.id == selection.profileID,
              let stream = library.stream(withID: recording.stream.id), stream.hasCatchUp else {
            unavailable()
            return
        }
        do {
            // Revalidate the selected listing, not the whole replay catalog,
            // before opening its exact archive interval. Never fall back live.
            let current: [CatchUpProgramme]
            if selection.usesChannelCatchUp {
                // Sports' Catch Up entry has the same current/past program
                // semantics as Guide, including a program still being recorded.
                current = try await library.catchUpProgrammes(for: stream)
            } else {
                current = try await library.gameReplayProgrammes(for: stream, profileID: selection.profileID)
            }
            guard !Task.isCancelled, library.activeProfile?.id == selection.profileID else { return }
            guard let program = current.first(where: { $0.id == recording.program.id && $0.title == recording.program.title && $0.end == recording.program.end }) else {
                unavailable()
                return
            }
            await controller.openRecording(of: stream, programme: program, from: library, requiresRecording: true)
        } catch {
            if !Task.isCancelled { unavailable() }
        }
    }

    private func unavailable() {
        controller.loading = false
        controller.error = "This replay couldn't be opened. Refresh Game Replays or try again."
    }
}
