import Foundation
import CryptoKit
import LineupAetherPlayback

struct LiveSourceQuality: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let frameRate: Double?

    var isValid: Bool { width > 0 && height > 0 && width <= 16384 && height <= 16384 }
    var pixels: Int { isValid ? width * height : 0 }
    var label: String { "\(min(width, height))p" }

    func outranks(_ other: Self) -> Bool {
        if pixels != other.pixels { return pixels > other.pixels }
        let rate = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let otherRate = other.frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        return rate > otherRate
    }
}

/// One short deadline includes queue time and every URL, with no overlapping
/// provider probes. New requests cancel stale work rather than queue full scans.
actor LiveQualityVerifier {
    static let shared = LiveQualityVerifier()
    static let startupBudget: TimeInterval = 4
    static let perURLBudget: TimeInterval = 1.25
    struct Candidate: Sendable {
        let id: Int
        let urls: [URL]
        let context: String
        var languageRank: Int = 0
    }
    struct Entry: Codable {
        let quality: LiveSourceQuality?
        let expires: Date
        var urlIndex: Int? = nil
        var samples: [Int: Sample]? = nil
    }
    struct Sample: Codable, Sendable {
        let quality: LiveSourceQuality?
        let expires: Date
    }
    struct Selection: Equatable, Sendable {
        let streamID: Int
        var urlIndex: Int? = nil
        var wasCancelled = false
    }
    typealias Probe = @Sendable (URL, TimeInterval) async throws -> LiveSourceQuality
    private let probe: Probe
    private let uptime: @Sendable () -> TimeInterval
    private let defaults: UserDefaults?
    private var cache: [String: Entry]
    private var active: (id: UUID, task: Task<Selection, Never>)?
    private static let cacheKey = "lineup.live-source-quality.v1"

    init(defaults: UserDefaults? = .standard,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         probe: @escaping Probe = { url, timeout in
        let result = try await AetherSourceProbe.quality(url: url, timeout: timeout)
        return LiveSourceQuality(width: result.width, height: result.height, frameRate: result.frameRate)
    }) {
        self.defaults = defaults
        self.probe = probe
        self.uptime = uptime
        cache = defaults?.data(forKey: Self.cacheKey).flatMap {
            try? JSONDecoder().decode([String: Entry].self, from: $0)
        } ?? [:]
    }

    static func key(_ candidate: Candidate) -> String {
        // Neither credential-bearing URLs nor provider/event names go to disk.
        SHA256.hash(data: Data(([candidate.context, String(candidate.id)] + candidate.urls.map(\.absoluteString))
            .joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func best(_ candidates: [Candidate], fallback fallbackID: Int,
              budget: TimeInterval = LiveQualityVerifier.startupBudget) async -> Selection {
        let fallback = Selection(streamID: fallbackID)
        guard !Task.isCancelled else { return Selection(streamID: fallbackID, wasCancelled: true) }
        let deadline = uptime() + (budget.isFinite ? max(0, budget) : Self.startupBudget)
        let previous = active?.task
        previous?.cancel()
        let id = UUID()
        let work = Task { [weak self] () -> Selection in
            await previous?.value
            guard !Task.isCancelled else { return Selection(streamID: fallbackID, wasCancelled: true) }
            guard let self else { return fallback }
            return await self.measure(candidates, fallback: fallback, deadline: deadline)
        }
        active = (id, work)
        let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        if active?.id == id { active = nil }
        return result
    }

    private func measure(_ candidates: [Candidate], fallback: Selection, deadline: TimeInterval) async -> Selection {
        defer { persist() }
        let now = Date()
        var samples = Array(repeating: [Int: Sample](), count: candidates.count)
        var legacy: [Int: Entry] = [:]
        var shared: [String: Sample] = [:]
        // Read ALL cached candidates before spending any time on the network.
        // A cold/failed first channel cannot hide a cached high-quality later one.
        for (index, candidate) in candidates.enumerated() {
            guard let saved = cache[Self.key(candidate)], saved.expires > now else { continue }
            if let known = saved.samples {
                samples[index] = known.filter { candidate.urls.indices.contains($0.key) && $0.value.expires > now }
                for (urlIndex, sample) in samples[index] {
                    shared[Self.sourceKey(candidate, urlIndex)] = sample
                }
            } else if saved.quality == nil || (saved.quality?.isValid == true
                && saved.urlIndex.map({ candidate.urls.indices.contains($0) }) == true) {
                // Existing installs' completed candidate measurements remain valid.
                legacy[index] = saved
            }
        }
        let ranks = Set(candidates.map(\.languageRank)).sorted()
        network: for rank in ranks {
            let bestKnownRank = candidates.indices.filter { index in
                legacy[index]?.quality?.isValid == true || samples[index].values.contains { $0.quality?.isValid == true }
            }.map { candidates[$0].languageRank }.min()
            if let bestKnownRank, bestKnownRank < rank { continue }
            let indices = candidates.indices.filter { candidates[$0].languageRank == rank }
            let orders = indices.map { Self.urlOrder(candidates[$0].urls) }
            // Compare channels before spending another socket open on a channel's
            // alternate transport. TS is a direct media read, so try it before HLS.
            for round in 0..<(orders.map(\.count).max() ?? 0) {
                for (slot, index) in indices.enumerated() {
                    guard !Task.isCancelled else { return Selection(streamID: fallback.streamID, wasCancelled: true) }
                    guard legacy[index] == nil, orders[slot].indices.contains(round) else { continue }
                    let urlIndex = orders[slot][round]
                    guard samples[index][urlIndex] == nil else { continue }
                    let candidate = candidates[index]
                    let sourceKey = Self.sourceKey(candidate, urlIndex)
                    let sample: Sample
                    if let reused = shared[sourceKey] { sample = reused }
                    else {
                        let remaining = deadline - uptime()
                        if remaining <= 0 { break network }
                        let value = try? await probe(candidate.urls[urlIndex], min(Self.perURLBudget, remaining))
                        guard !Task.isCancelled else { return Selection(streamID: fallback.streamID, wasCancelled: true) }
                        let quality = value.flatMap { $0.isValid ? $0 : nil }
                        sample = Sample(quality: quality, expires: Date().addingTimeInterval(quality == nil ? 30 : 600))
                        shared[sourceKey] = sample
                    }
                    samples[index][urlIndex] = sample
                    let best = samples[index].filter { $0.value.quality?.isValid == true }.max {
                        $1.value.quality!.outranks($0.value.quality!)
                    }
                    cache[Self.key(candidate)] = Entry(quality: best?.value.quality,
                        expires: samples[index].values.map(\.expires).max() ?? now,
                        urlIndex: best?.key, samples: samples[index])
                }
            }
        }
        var winner: (Selection, LiveSourceQuality, Int)?
        for (index, candidate) in candidates.enumerated() {
            var measured = samples[index].compactMap { urlIndex, sample -> (Int, LiveSourceQuality)? in
                sample.quality.flatMap { $0.isValid ? (urlIndex, $0) : nil }
            }.sorted { $0.0 < $1.0 }
            if let saved = legacy[index], let quality = saved.quality, let url = saved.urlIndex {
                measured.append((url, quality))
            }
            for (urlIndex, quality) in measured {
                if winner == nil || candidate.languageRank < winner!.2
                    || (candidate.languageRank == winner!.2 && quality.outranks(winner!.1)) {
                    winner = (Selection(streamID: candidate.id, urlIndex: urlIndex), quality, candidate.languageRank)
                }
            }
        }
        return winner?.0 ?? fallback
    }

    private static func urlOrder(_ urls: [URL]) -> [Int] {
        urls.indices.sorted {
            let left = urls[$0].pathExtension.lowercased() == "ts"
            let right = urls[$1].pathExtension.lowercased() == "ts"
            return left != right ? left : $0 < $1
        }
    }

    private static func sourceKey(_ candidate: Candidate, _ index: Int) -> String {
        SHA256.hash(data: Data((candidate.context + "\n" + candidate.urls[index].absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func persist() {
        cache = cache.filter { $0.value.expires > Date() }
        if let data = try? JSONEncoder().encode(cache) { defaults?.set(data, forKey: Self.cacheKey) }
    }
}
