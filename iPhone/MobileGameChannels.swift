import Foundation

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
        let root = library.providerRoot
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
        if let active {
            let matched = await root.eventChannels(for: game)
            guard !Task.isCancelled else { return }
            let streams = root.streams, categories = root.categories, programs = root.programsByChannel
            let taken = Set(matched.map(\.id))
            let fallback = await Task.detached(priority: .userInitiated) {
                NetworkChannelFallback.channels(for: game, streams: streams, categories: categories,
                                                programs: programs, excluding: taken)
            }.value
            guard !Task.isCancelled else { return }
            results.confirmed += matched.map { MobileProviderChannel(profile: active, channel: $0) }
            results.network += fallback.map { MobileProviderChannel(profile: active, channel: $0) }
            publish()
        }
        let others = profiles.filter { $0.id != active?.id }.map { ($0, KeychainStore.password(profileID: $0.id)) }
        await withTaskGroup(of: (UUID, [LiveEventChannel], [LiveEventChannel], String?).self) { group in
            for (profile, secret) in others {
                group.addTask { await channels(in: profile, secret: secret, game: game, board: board) }
            }
            for await (id, matched, fallback, issue) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                guard let profile = root.profiles.first(where: { $0.id == id }),
                      let original = profiles.first(where: { $0.id == id }),
                      SportsLibrary.sameProviderConnection(profile, original) else { continue }
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
