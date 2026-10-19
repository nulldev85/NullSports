import SwiftUI

/// A focused alternative-feed list. The broad searchable picker stays separate.
@MainActor
struct MobileEventChannelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let library: SportsLibrary
    let game: SportsGame
    let playingID: Int?
    let onPick: (XtreamStream) -> Void
    @State private var channels: [LiveEventChannel] = []
    @State private var loading = true
    @State private var waiting = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var openedProfileID: UUID?

    init(library: SportsLibrary, game: SportsGame, playingID: Int?, onPick: @escaping (XtreamStream) -> Void) {
        self.library = library; self.game = game; self.playingID = playingID; self.onPick = onPick
        _openedProfileID = State(initialValue: library.activeProfile?.id)
    }

    private var current: SportsGame { library.gamesByLeague[game.league]?.first { $0.id == game.id } ?? game }

    var body: some View {
        MobileEventChannelsContent(game: current, channels: channels, loading: loading,
            waiting: waiting, playingID: playingID, onPick: { entry in
                // A displayed row can outlive its guide evidence. Revalidate
                // when pressed, before a manual selection is ever recorded.
                guard library.activeProfile?.id == openedProfileID else { dismiss(); return }
                guard current.isLive || current.isUpcoming,
                      let stream = library.stream(withID: entry.id),
                      stream.name == entry.stream.name, stream.epgChannelID == entry.stream.epgChannelID,
                      library.isEventChannel(stream, verifiedFor: current) else { reload(); return }
                onPick(stream)
            }, onClose: { dismiss() })
            .presentationDetents([.medium, .large])
            .presentationBackground(LineupStyle.background)
            .presentationDragIndicator(.visible)
            .onAppear { reload() }
            .onChange(of: library.eventChannelsInputs) { reload() }
            .onDisappear { reloadTask?.cancel() }
    }

    private func reload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            // Published sends before mutation; coalesce that publication turn.
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

struct MobileEventChannelsContent: View {
    let game: SportsGame
    let channels: [LiveEventChannel]
    let loading: Bool
    let waiting: Bool
    let playingID: Int?
    let onPick: (LiveEventChannel) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                LineupIconTile(symbol: "tv", size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Channels").font(.inter(22, .bold))
                    Text(game.matchupLine).font(.inter(13, .semibold))
                        .foregroundStyle(LineupPanelStyle.quiet).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(LineupPanelStyle.well, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close Channels")
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 16)
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.horizontal, 20)
            if loading || waiting {
                ProgressView(waiting ? "Matching event channels…" : "Finding channels…")
                    .font(.inter(15)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if channels.isEmpty {
                LineupUnavailableView("No matching channels", systemImage: "tv.slash",
                    description: Text("No channels could be verified for this event. You can search your provider using Choose Another Channel in the event menu."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("\(channels.count) \(channels.count == 1 ? "CHANNEL" : "CHANNELS")")
                            .font(.inter(11, .heavy)).tracking(1).foregroundStyle(LineupPanelStyle.caption)
                            .padding(.bottom, 2)
                        ForEach(channels) { channel in
                            MobileEventChannelRow(channel: channel, isPlaying: channel.id == playingID,
                                live: game.isLive, fallback: game.matchupLine) { onPick(channel) }
                        }
                    }
                    .padding(20)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .foregroundStyle(LineupStyle.text)
        .background(LineupStyle.background.ignoresSafeArea())
    }
}

private struct MobileEventChannelRow: View {
    let channel: LiveEventChannel
    let isPlaying: Bool
    let live: Bool
    let fallback: String
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                TeamBadge(url: channel.stream.streamIcon ?? "", fallback: "TV", size: 44, tight: true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(channel.stream.name).font(.inter(15, .bold)).lineLimit(2)
                    Text(channel.program?.title ?? fallback).font(.inter(12))
                        .foregroundStyle(LineupPanelStyle.quiet).lineLimit(2)
                    HStack(spacing: 8) {
                        if live {
                            HStack(spacing: 4) {
                                Circle().fill(LineupStyle.liveStatus).frame(width: 5, height: 5)
                                Text("Live now").foregroundStyle(LineupStyle.liveStatus)
                            }
                        }
                        if let label = channel.quality.label {
                            Text("Provider \(label)").foregroundStyle(LineupStyle.secondary)
                                .accessibilityLabel("Provider quality: \(label)")
                        }
                    }.font(.inter(11, .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(LineupStyle.onHighlight)
                    .frame(width: 40, height: 40).background(LineupStyle.highlight, in: Circle())
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
            .contentShape(LineupPanelStyle.shape)
        }
        .buttonStyle(MobileCardButtonStyle())
        .accessibilityIdentifier("EventChannel-\(channel.id)")
        .accessibilityHint(isPlaying ? "Currently playing. Select to restart this channel." : "Play this event on this channel")
    }
}
