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
        MobileEventChannelsContent(game: current, channels: channels, loading: loading,
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
            .presentationBackground(LineupStyle.background)
            .presentationDragIndicator(.visible)
            .task(id: library.eventChannelsInputs + [AnyHashable(retry)]) { await load() }
    }

    private func reload() {
        retry += 1
    }

    private func load() async {
        guard library.activeProfile?.id == openedProfileID else { dismiss(); return }
        let event = current
        let profiles = library.enabledProfiles
        let board = library.eventChannelTournamentBoard
        loading = true
        providerIssues = []
        waiting = !library.eventChannelsReady(for: event) && library.channelsAreSyncing
        let active = await library.eventChannels(for: event)
        guard !Task.isCancelled else { return }
        channels = profiles.first(where: { $0.id == openedProfileID }).map { profile in
            active.map { MobileProviderChannel(profile: profile, channel: $0) }
        } ?? []
        // Do not wait on slower services before displaying the active provider.
        let jobs = profiles.filter { $0.id != openedProfileID }.map { profile in
            (profile, KeychainStore.password(profileID: profile.id))
        }
        await withTaskGroup(of: (UUID, [LiveEventChannel]?, String?).self) { group in
            for job in jobs.prefix(2) {
                group.addTask { await Self.matchProvider(job.0, secret: job.1, game: event, board: board) }
            }
            var next = 2
            while let (id, matches, issue) = await group.next() {
                guard !Task.isCancelled, library.activeProfile?.id == openedProfileID else {
                    group.cancelAll(); break
                }
                if let profile = library.profiles.first(where: { $0.id == id }),
                   let original = profiles.first(where: { $0.id == id }),
                   SportsLibrary.sameProviderConnection(profile, original) {
                    if let matches { channels += matches.map { MobileProviderChannel(profile: profile, channel: $0) } }
                    if let issue { providerIssues.append(.init(id: profile.id, message: "\(profile.name): \(issue)")) }
                }
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { await Self.matchProvider(job.0, secret: job.1, game: event, board: board) }
                }
            }
        }
        guard !Task.isCancelled else { return }
        // Completion order varies by server; display order stays predictable.
        let order = Dictionary(uniqueKeysWithValues: profiles.enumerated().map { ($1.id, $0) })
        channels = channels.enumerated().sorted {
            let left = order[$0.element.profile.id] ?? Int.max
            let right = order[$1.element.profile.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        loading = false
    }

    nonisolated private static func matchProvider(_ profile: XtreamProfile, secret: String?,
        game: SportsGame, board: [[String]]) async -> (UUID, [LiveEventChannel]?, String?) {
        guard let secret else { return (profile.id, nil, "Sign in again in Settings → IPTV") }
        do {
            let snapshot = try await MobileProviderCatalog.shared.snapshot(for: profile, secret: secret)
            try Task.checkCancellation()
            let work = Task.detached(priority: .userInitiated) { snapshot.matching(game, board: board) }
            let matches = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            return (profile.id, matches, nil)
        } catch { return (profile.id, nil, "Could not load channels or guide") }
    }
}

struct MobileEventChannelsContent: View {
    let game: SportsGame
    let channels: [MobileProviderChannel]
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
            if (loading || waiting) && channels.isEmpty && providerIssues.isEmpty {
                ProgressView(waiting ? "Matching event channels…" : "Finding channels…")
                    .font(.inter(15)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let name = activeProviderName {
                            Label("Playing provider: \(name)", systemImage: "checkmark.circle.fill")
                                .font(.inter(12, .semibold)).foregroundStyle(LineupStyle.secondary)
                        }
                        Text("Channels from all enabled providers")
                            .font(.inter(11)).foregroundStyle(LineupPanelStyle.quiet)
                        ForEach(providerIssues) { issue in
                            Label(issue.message, systemImage: "exclamationmark.triangle")
                                .font(.inter(12)).foregroundStyle(LineupStyle.secondary)
                        }
                        if loading { ProgressView("Checking other providers…").font(.inter(12)) }
                        if channels.isEmpty && !loading {
                            LineupUnavailableView("No matching channels", systemImage: "tv.slash",
                                description: Text("No channels could be verified for this event. You can search your provider using Choose Another Channel in the event menu."))
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                        }
                        Text("\(channels.count) \(channels.count == 1 ? "CHANNEL" : "CHANNELS")")
                            .font(.inter(11, .heavy)).tracking(1).foregroundStyle(LineupPanelStyle.caption)
                            .padding(.bottom, 2)
                        Text("Quality labels supplied by your provider")
                            .font(.inter(11)).foregroundStyle(LineupPanelStyle.quiet)
                        ForEach(MobileProviderChannelSection.grouped(channels)) { section in
                            Text(section.title)
                                .font(.inter(15, .heavy)).foregroundStyle(LineupPanelStyle.caption)
                                .padding(.top, 8).accessibilityAddTraits(.isHeader)
                            ForEach(section.channels) { channel in
                                MobileEventChannelRow(source: channel,
                                    isPlaying: channel.id.streamID == playingID && channel.id.providerID == playingProfileID,
                                    live: game.isLive, fallback: game.matchupLine) { onPick(channel) }
                            }
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
                        .font(.inter(11, .semibold)).foregroundStyle(LineupStyle.secondary).lineLimit(1)
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
                            Text(label).foregroundStyle(LineupStyle.secondary)
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
        .accessibilityIdentifier("EventChannel-\(source.profile.id)-\(channel.id)")
        .accessibilityHint(isPlaying ? "Currently playing. Select to restart this channel." : "Play this event on this channel")
    }
}
