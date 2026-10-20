import Foundation
import Combine

@MainActor
final class MobileGameReplayStore: ObservableObject {
    struct Request: Hashable {
        let profileID: UUID?
        let playlist: Bool
        let refreshed: Date?
        let channelCount: Int
        let followedIDs: [String]
        let enabled: Bool
        var refresh: Int = 0
    }
    private struct CacheKey: Hashable { let profile: UUID; let stream: XtreamStream }
    private struct Cached { let at: Date; let programs: [CatchUpProgramme] }
    @Published private(set) var request: Request?
    private(set) var recordings: [MobileGameReplayRecording] = []
    @Published private(set) var replays: [MobileGameReplay] = []
    @Published private(set) var loading = false
    @Published private(set) var failedChannels = 0
    @Published private(set) var candidateCount = 0
    private var generation = UUID()
    private var cache: [CacheKey: Cached] = [:]

    func cancel() { generation = UUID(); loading = false }
    func clearCache() { cache.removeAll() }

    func load(_ request: Request, streams: [XtreamStream], categories: [XtreamCategory],
              teams: [MobileGameReplayPolicy.Team], force: Bool = false,
              fetch: @escaping @Sendable (XtreamStream) async throws -> [CatchUpProgramme]) async {
        let token = UUID()
        generation = token
        self.request = request
        recordings = []
        replays = []
        failedChannels = 0
        candidateCount = 0
        guard request.enabled, let profileID = request.profileID, !request.playlist, !request.followedIDs.isEmpty else {
            loading = false
            return
        }
        loading = true
        defer { if generation == token { loading = false } }
        let followed = Set(request.followedIDs)
        let scan = Task.detached(priority: .utility) {
            MobileGameReplayPolicy.candidates(streams: streams, categories: categories, followed: followed, teams: teams)
        }
        let candidates = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
        guard !Task.isCancelled, generation == token else { return }
        candidateCount = candidates.count
        var missing: [XtreamStream] = []
        for stream in candidates {
            let key = CacheKey(profile: profileID, stream: stream)
            if !force, let cached = cache[key], Date().timeIntervalSince(cached.at) < 300 {
                recordings += cached.programs.map { MobileGameReplayRecording(stream: stream, program: $0) }
            } else { missing.append(stream) }
        }
        await publish(teams: teams, followed: followed, token: token)
        guard !Task.isCancelled, generation == token else { return }
        // A small pool, not a connection per channel. Results publish as they
        // arrive; this work never joins startup refresh/matching progress.
        await withTaskGroup(of: (XtreamStream, Result<[CatchUpProgramme], Error>).self) { group in
            let initial = min(3, missing.count)
            var next = initial
            for stream in missing.prefix(initial) {
                group.addTask {
                    do { return (stream, .success(try await fetch(stream))) }
                    catch { return (stream, .failure(error)) }
                }
            }
            for await (stream, answer) in group {
                guard !Task.isCancelled, generation == token else { group.cancelAll(); break }
                switch answer {
                case .success(let programs):
                    if cache.count >= 256 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < 300 }; if cache.count >= 256 { cache.removeAll() } }
                    cache[CacheKey(profile: profileID, stream: stream)] = Cached(at: Date(), programs: programs)
                    recordings += programs.map { MobileGameReplayRecording(stream: stream, program: $0) }
                    await publish(teams: teams, followed: followed, token: token)
                case .failure(let error):
                    if !(error is CancellationError) { failedChannels += 1 }
                }
                guard !Task.isCancelled, generation == token else { group.cancelAll(); break }
                if next < missing.count {
                    let stream = missing[next]
                    next += 1
                    group.addTask {
                        do { return (stream, .success(try await fetch(stream))) }
                        catch { return (stream, .failure(error)) }
                    }
                }
            }
        }
        guard !Task.isCancelled, generation == token else { return }
        loading = false
    }

    private func publish(teams: [MobileGameReplayPolicy.Team], followed: Set<String>, token: UUID) async {
        let recordings = recordings
        let build = Task.detached(priority: .utility) {
            MobileGameReplayPolicy.replays(recordings: recordings, followed: followed, teams: teams, now: Date())
        }
        let result = await withTaskCancellationHandler(operation: { await build.value }, onCancel: { build.cancel() })
        guard !Task.isCancelled, generation == token else { return }
        replays = result
    }
}
