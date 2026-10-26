import Foundation
import CryptoKit

@MainActor
struct MobileProviderPlaybackSource {
    let library: SportsLibrary
    let stream: XtreamStream
}

/// Numbered channel IDs are unique only inside the account that issued them.
struct MobileProviderChannel: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let providerID: UUID
        let streamID: Int
    }
    let profile: XtreamProfile
    let channel: LiveEventChannel
    var id: ID { ID(providerID: profile.id, streamID: channel.id) }
}

struct MobileProviderIssue: Identifiable {
    let id: UUID
    let message: String
}

struct MobileProviderSnapshot: Sendable {
    let categories: [XtreamCategory]
    let streams: [XtreamStream]
    let programs: [String: [CurrentProgram]]
    let fetchedAt: Date

    func matching(_ game: SportsGame, board: [[String]], now: Date = Date()) -> [LiveEventChannel] {
        SportsLibrary.matchingEventChannels(for: game, candidates: streams, programs: programs,
            categories: categories, board: board, now: now)
    }

    func verifiedStream(_ choice: MobileProviderChannel, game: SportsGame, board: [[String]]) -> XtreamStream? {
        guard game.isLive || game.isUpcoming, Date().timeIntervalSince(fetchedAt) < 120 else { return nil }
        return matching(game, board: board).first {
            $0.stream == choice.channel.stream
        }?.stream
    }
}

/// On-demand metadata only; this never opens/probes a playback stream. At most
/// two providers load together. A failed provider cannot discard another's feeds.
actor MobileProviderCatalog {
    static let shared = MobileProviderCatalog()
    typealias Loader = @Sendable (XtreamProfile, String) async throws -> MobileProviderSnapshot
    private let loader: Loader
    private var cached: [String: MobileProviderSnapshot] = [:]
    private var pending: [String: Task<MobileProviderSnapshot, Error>] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func invalidate() { cached.removeAll() }

    init(loader: @escaping Loader = { profile, secret in try await MobileProviderCatalog.download(profile, secret: secret) }) {
        self.loader = loader
    }

    private static func key(_ profile: XtreamProfile, secret: String) -> String {
        // Renaming is harmless; changing any connection input retires its cache.
        let data = (try? JSONEncoder().encode([profile.id.uuidString, profile.serverURL,
            profile.username, profile.connectionKind ?? "", secret])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func snapshot(for profile: XtreamProfile, secret: String) async throws -> MobileProviderSnapshot {
        let key = Self.key(profile, secret: secret)
        try Task.checkCancellation()
        cached = cached.filter { Date().timeIntervalSince($0.value.fetchedAt) < 120 }
        if let value = cached[key] { return value }
        // Coalesce reopening/reloading the sheet; the bounded request can finish
        // for another observer, while canceled callers never publish its result.
        if let task = pending[key] { return try await task.value }
        while pending.count >= 2 {
            try await waitForSlot()
            try Task.checkCancellation()
            if let value = cached[key] { return value }
            if let task = pending[key] { return try await task.value }
        }
        let load = loader
        let task = Task { try await load(profile, secret) }
        pending[key] = task
        defer {
            pending[key] = nil
            let ready = Array(waiters.values)
            waiters.removeAll()
            for waiter in ready { waiter.resume() }
        }
        let result = try await task.value
        if cached.count >= 3, let oldest = cached.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            cached[oldest] = nil
        }
        cached[key] = result
        return result
    }

    private func waitForSlot() async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
            }
        }, onCancel: { Task { await self.cancelWaiter(id) } })
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    nonisolated static func download(_ profile: XtreamProfile, secret: String) async throws -> MobileProviderSnapshot {
        let client = XtreamClient(profile: profile, password: secret)
        async let categories = client.categories(ifChangedFrom: nil)
        async let streams = client.streams(ifChangedFrom: nil)
        async let programs = client.programsToday(ifChangedFrom: nil)
        let result = try await (categories, streams, programs)
        guard let groups = result.0.payload?.value, let channels = result.1.payload?.value,
              let guide = result.2.payload?.value else { throw XtreamClient.XtreamError.invalidResponse }
        return MobileProviderSnapshot(categories: groups, streams: channels, programs: guide, fetchedAt: Date())
    }
}

struct MobileProviderChannelSection: Identifiable {
    let height: Int
    let channels: [MobileProviderChannel]
    var id: Int { height }
    var title: String { MobileEventChannelSection(height: height, channels: []).title }
    static func grouped(_ channels: [MobileProviderChannel]) -> [Self] {
        let groups = Dictionary(grouping: channels, by: { $0.channel.quality.height })
        return groups.keys.sorted(by: >).map { Self(height: $0, channels: groups[$0] ?? []) }
    }
}
