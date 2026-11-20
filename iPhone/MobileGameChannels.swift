import SwiftUI

/// What a game's channels are, as they come in: those a guide confirms, from
/// the playing playlist first and then every other one; apart from those,
/// each playlist's feeds of the network the game is on; and any playlist
/// that could not be read.
struct MobileGameChannelResults {
    var confirmed: [MobileProviderChannel] = []
    var network: [MobileProviderChannel] = []
    var issues: [MobileProviderIssue] = []
    /// Every playlist has answered.
    var finished = false
}

/// A game's channels in every enabled playlist, found the same way for the
/// page a game still to come opens and for Channels on a live one.
enum MobileGameChannels {
    /// Hands each step's results to `update` as it arrives, in the order the
    /// playlists were added. Stops, handing on nothing more, if cancelled.
    @MainActor
    static func find(in library: SportsLibrary, game: SportsGame,
                     update: (MobileGameChannelResults) -> Void) async {
        #if os(iOS)
        let root = library.providerRoot
        #else
        let root = library
        #endif
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
        var results = MobileGameChannelResults()
        func publish() {
            results.confirmed = ordered(results.confirmed)
            results.network = ordered(results.network)
            update(results)
        }
        let active = root.activeProfile.flatMap { profile in order[profile.id] == nil ? nil : profile }
        #if os(tvOS)
        let prepared = root.preparedEventChannels(for: game) ?? []
        #else
        let prepared: [LiveEventChannel]
        if active != nil { prepared = await root.eventChannels(for: game) }
        else { prepared = [] }
        #endif
        guard !Task.isCancelled else { return }
        if let active, !prepared.isEmpty {
            results.confirmed = prepared.map { MobileProviderChannel(profile: active, channel: $0) }
            publish()
        }
        let snapshot = MobileProviderSnapshot(categories: root.categories, streams: root.streams,
            programs: root.programsByChannel, fetchedAt: Date())
        let others = profiles.filter { $0.id != active?.id }.map { ($0, KeychainStore.password(profileID: $0.id)) }
        await withTaskGroup(of: (UUID, [LiveEventChannel], [LiveEventChannel], String?).self) { group in
            if let active {
                group.addTask {
                    #if os(tvOS)
                    // Where to Watch needs the full guide, independently of the
                    // automatic shortlist used for quick playback.
                    let full = snapshot.matching(game, board: board)
                    let found = Set(full.map(\.id))
                    let matched = full + prepared.filter { !found.contains($0.id) }
                    #else
                    let matched = prepared
                    #endif
                    let fallback = NetworkChannelFallback.channels(for: game, streams: snapshot.streams,
                        categories: snapshot.categories, programs: snapshot.programs, excluding: Set(matched.map(\.id)))
                    return (active.id, matched, fallback, nil)
                }
            }
            for (profile, secret) in others {
                group.addTask { await channels(in: profile, secret: secret, game: game, board: board) }
            }
            for await (id, matched, fallback, issue) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                guard let profile = root.enabledProfiles.first(where: { $0.id == id }),
                      let original = profiles.first(where: { $0.id == id }),
                      SportsLibrary.sameProviderConnection(profile, original) else { continue }
                if id == active?.id { results.confirmed.removeAll { $0.profile.id == id } }
                results.confirmed += matched.map { MobileProviderChannel(profile: profile, channel: $0) }
                results.network += fallback.map { MobileProviderChannel(profile: profile, channel: $0) }
                if let issue { results.issues.append(.init(id: profile.id, message: "\(profile.name): \(issue)")) }
                publish()
            }
        }
        guard !Task.isCancelled else { return }
        results.finished = true
        publish()
    }

    /// One playlist other than the playing one, from its saved copy: the
    /// channels its guide confirms, and its feeds of the game's network.
    nonisolated static func channels(in profile: XtreamProfile, secret: String?, game: SportsGame,
                                     board: [[String]]) async -> (UUID, [LiveEventChannel], [LiveEventChannel], String?) {
        guard let secret else { return (profile.id, [], [], "Sign in again in Settings → IPTV") }
        guard let snapshot = try? await MobileProviderCatalog.shared.snapshot(for: profile, secret: secret) else {
            return (profile.id, [], [], "Could not load channels or guide")
        }
        let work = Task.detached(priority: .userInitiated) { () -> ([LiveEventChannel], [LiveEventChannel]) in
            let matched = snapshot.matching(game, board: board)
            let fallback = NetworkChannelFallback.channels(for: game, streams: snapshot.streams,
                categories: snapshot.categories, programs: snapshot.programs, excluding: Set(matched.map(\.id)))
            return (matched, fallback)
        }
        let (matched, fallback) = await withTaskCancellationHandler(operation: { await work.value },
                                                                     onCancel: { work.cancel() })
        return (profile.id, matched, fallback, nil)
    }
}

#if os(iOS)
/// A game's channels as Where to Watch lists them, on the page a game still
/// to come opens and in Channels on a live one: those a guide confirms from
/// every playlist, then each playlist's feeds of the game's network.
struct MobileWhereToWatch: View {
    let game: SportsGame
    let channels: [MobileProviderChannel]
    let networkChannels: [MobileProviderChannel]
    var issues: [MobileProviderIssue] = []
    /// Some playlist has yet to answer.
    let finding: Bool
    var playingID: Int?
    var playingProfileID: UUID?
    let onPick: (MobileProviderChannel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if channels.isEmpty && networkChannels.isEmpty {
                HStack(spacing: 10) {
                    if finding { ProgressView() }
                    Text(finding ? "Looking through your playlists…" : emptyMessage)
                        .font(.inter(14)).foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
                .padding(.horizontal, 16)
            }
            if !channels.isEmpty {
                list(channels, fallback: game.matchupLine)
            }
            if !networkChannels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On \(game.broadcast)").font(.inter(17, .bold))
                    Text("Your guide hasn't listed it on these yet, but \(game.broadcast) is showing it.")
                        .font(.inter(13)).foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20).padding(.top, channels.isEmpty ? 0 : 8)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                list(networkChannels, fallback: game.isLive ? "On \(game.broadcast)"
                     : "On \(game.broadcast) at " + game.start.formatted(date: .omitted, time: .shortened))
            }
            if finding && !(channels.isEmpty && networkChannels.isEmpty) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking your other playlists…").font(.inter(13))
                        .foregroundStyle(LineupPresentationStyle.secondary)
                }
                .padding(.horizontal, 20)
            }
            ForEach(issues) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.inter(12)).foregroundStyle(LineupPresentationStyle.secondary)
                    .padding(.horizontal, 20)
            }
        }
    }

    private var emptyMessage: String {
        game.isLive
            ? "Not in your playlists or guide. Choose Another Channel in the game's menu searches your provider."
            : "Not in your playlists or guide yet. Channels usually show up closer to the start."
    }

    private func list(_ list: [MobileProviderChannel], fallback: String) -> some View {
        VStack(spacing: 10) {
            ForEach(list) { channel in
                MobileEventChannelRow(source: channel,
                    isPlaying: channel.id.streamID == playingID && channel.id.providerID == playingProfileID,
                    live: game.isLive, fallback: fallback) { onPick(channel) }
            }
        }
        .padding(.horizontal, 16)
    }
}
#endif
