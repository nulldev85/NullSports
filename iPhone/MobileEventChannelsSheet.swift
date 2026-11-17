import SwiftUI

struct MobileEventChannelSection: Identifiable {
    let height: Int
    let channels: [LiveEventChannel]
    var id: Int { height }
    var title: String {
        switch height {
        case 4320: "8K"
        case 2160: "4K / UHD"
        case 1080: "1080p / Full HD"
        case 720: "720p / HD"
        case 0: "Quality not specified"
        default: "\(height)p"
        }
    }
    static func grouped(_ channels: [LiveEventChannel]) -> [Self] {
        let groups = Dictionary(grouping: channels, by: { $0.quality.height })
        return groups.keys.sorted(by: >).map { Self(height: $0, channels: groups[$0] ?? []) }
    }
}

/// A focused alternative-feed list. The broad searchable picker stays separate.
@MainActor
struct MobileEventChannelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let library: SportsLibrary
    let game: SportsGame
    let playingID: Int?
    let playingProfileID: UUID?
    let onPick: (MobileProviderChannel) -> Void
    @State private var channels: [MobileProviderChannel] = []
    /// Each playlist's feeds of the network the game is on, beyond those a
    /// guide confirms.
    @State private var networkChannels: [MobileProviderChannel] = []
    @State private var providerIssues: [MobileProviderIssue] = []
    @State private var loading = true
    @State private var waiting = false
    @State private var retry = 0
    @State private var openedProfileID: UUID?

    init(library: SportsLibrary, game: SportsGame, playingID: Int?, playingProfileID: UUID? = nil,
         onPick: @escaping (MobileProviderChannel) -> Void) {
        self.library = library.providerRoot; self.game = game; self.playingID = playingID; self.onPick = onPick
        self.playingProfileID = playingProfileID
        _openedProfileID = State(initialValue: library.providerRoot.activeProfile?.id)
    }

    private var current: SportsGame { library.gamesByLeague[game.league]?.first { $0.id == game.id } ?? game }

    var body: some View {
        MobileEventChannelsContent(game: current, channels: channels, networkChannels: networkChannels,
            loading: loading,
            waiting: waiting, playingID: playingID, playingProfileID: playingProfileID,
            activeProviderName: library.profiles.first { $0.id == playingProfileID }?.name, providerIssues: providerIssues, onPick: { entry in
                // Activation revalidates this exact source and evidence after
                // the sheet dismisses, before recording a manual preference.
                guard library.activeProfile?.id == openedProfileID else { dismiss(); return }
                guard current.isLive || current.isUpcoming,
                      library.isProviderEnabled(entry.profile.id),
                      library.profiles.contains(where: {
                          SportsLibrary.sameProviderConnection($0, entry.profile)
                      }) else { reload(); return }
                onPick(entry)
            }, onClose: { dismiss() })
            .presentationDetents([.medium, .large])
            .presentationBackground(LineupPresentationStyle.ground)
            .presentationDragIndicator(.visible)
            .task(id: library.eventChannelsInputs + [AnyHashable(retry)]) { await load() }
    }

    private func reload() {
        retry += 1
    }

    /// The game's channels in every enabled playlist, found as the page a
    /// game still to come finds them: those a guide confirms, then each
    /// playlist's feeds of the network the game is on.
    private func load() async {
        guard library.activeProfile?.id == openedProfileID else { dismiss(); return }
        let event = current
        loading = true
        waiting = !library.eventChannelsReady(for: event) && library.channelsAreSyncing
        await MobileGameChannels.find(in: library, game: event) { results in
            guard library.activeProfile?.id == openedProfileID else { return }
            channels = results.confirmed
            networkChannels = results.network
            providerIssues = results.issues
            if results.finished { loading = false }
        }
        guard library.activeProfile?.id == openedProfileID else { dismiss(); return }
    }
}

struct MobileEventChannelsContent: View {
    let game: SportsGame
    let channels: [MobileProviderChannel]
    var networkChannels: [MobileProviderChannel] = []
    let loading: Bool
    let waiting: Bool
    let playingID: Int?
    let playingProfileID: UUID?
    let activeProviderName: String?
    let providerIssues: [MobileProviderIssue]
    let onPick: (MobileProviderChannel) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                LineupIconTile(symbol: "tv", size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Channels").font(.inter(22, .bold))
                    Text(game.matchupLine).font(.inter(13, .semibold))
                        .foregroundStyle(LineupPresentationStyle.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(LineupPresentationStyle.row, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close Channels")
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 16)
            Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1).padding(.horizontal, 20)
            if (loading || waiting) && channels.isEmpty && networkChannels.isEmpty && providerIssues.isEmpty {
                ProgressView(waiting ? "Matching event channels…" : "Looking through your playlists…")
                    .font(.inter(15)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // As the page a game still to come opens lists them:
                    // what a guide confirms from every playlist, then each
                    // playlist's feeds of the game's network.
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let name = activeProviderName {
                            Label("Playing provider: \(name)", systemImage: "checkmark.circle.fill")
                                .font(.inter(12, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                        }
                        ForEach(providerIssues) { issue in
                            Label(issue.message, systemImage: "exclamationmark.triangle")
                                .font(.inter(12)).foregroundStyle(LineupPresentationStyle.secondary)
                        }
                        if channels.isEmpty && networkChannels.isEmpty && !loading {
                            LineupUnavailableView("No matching channels", systemImage: "tv.slash",
                                description: Text("No channels could be found for this event in your playlists. You can search your provider using Choose Another Channel in the event menu."))
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                        }
                        ForEach(channels) { channel in row(channel, fallback: game.matchupLine) }
                        if !networkChannels.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("On \(game.broadcast)").font(.inter(17, .bold))
                                Text("Your guide doesn't list it on these, but \(game.broadcast) is showing it.")
                                    .font(.inter(13)).foregroundStyle(LineupPresentationStyle.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, channels.isEmpty ? 0 : 10).padding(.horizontal, 4)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(networkChannels) { channel in row(channel, fallback: "On \(game.broadcast)") }
                        }
                        if loading && !(channels.isEmpty && networkChannels.isEmpty) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Checking your other playlists…").font(.inter(13))
                                    .foregroundStyle(LineupPresentationStyle.secondary)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(20)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .foregroundStyle(LineupPresentationStyle.text)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
    }

    private func row(_ channel: MobileProviderChannel, fallback: String) -> some View {
        MobileEventChannelRow(source: channel,
            isPlaying: channel.id.streamID == playingID && channel.id.providerID == playingProfileID,
            live: game.isLive, fallback: fallback) { onPick(channel) }
    }
}

struct MobileEventChannelRow: View {
    let source: MobileProviderChannel
    private var channel: LiveEventChannel { source.channel }
    let isPlaying: Bool
    let live: Bool
    let fallback: String
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                TeamBadge(url: channel.stream.streamIcon ?? "", fallback: "TV", size: 44, tight: true)
                VStack(alignment: .leading, spacing: 5) {
                    Label(source.profile.name, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.inter(11, .semibold)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                    Text(channel.stream.name).font(.inter(15, .bold)).lineLimit(2)
                    Text(channel.program?.title ?? fallback).font(.inter(12))
                        .foregroundStyle(LineupPresentationStyle.secondary).lineLimit(2)
                    HStack(spacing: 8) {
                        if live {
                            HStack(spacing: 4) {
                                Circle().fill(LineupStyle.liveStatus).frame(width: 5, height: 5)
                                Text("Live now").foregroundStyle(LineupStyle.liveStatus)
                            }
                        }
                        if let label = channel.quality.label {
                            Text(label).foregroundStyle(LineupPresentationStyle.secondary)
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
            .background {
                LineupChannelArtworkTint(url: channel.stream.streamIcon.flatMap(URL.init(string:)), width: 88,
                    fallback: LineupPresentationStyle.card).clipShape(LineupPanelStyle.shape)
            }
            .contentShape(LineupPanelStyle.shape)
        }
        .buttonStyle(MobileCardButtonStyle())
        .accessibilityIdentifier("EventChannel-\(source.profile.id)-\(channel.id)")
        .accessibilityHint(isPlaying ? "Currently playing. Select to restart this channel." : "Play this event on this channel")
    }
}
