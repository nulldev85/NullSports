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
        // Scheduling hint only. Never substituted for a measured quality.
        var advertisedHeight: Int = 0
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
        var quality: LiveSourceQuality? = nil
    }
    typealias Probe = @Sendable (URL, TimeInterval) async throws -> LiveSourceQuality
    private let probe: Probe
    private let uptime: @Sendable () -> TimeInterval
    private let defaults: UserDefaults?
    private var cache: [String: Entry]
    private var played: [String: Sample]
    private var active: (id: UUID, task: Task<Selection, Never>)?
    private static let cacheKey = "lineup.live-source-quality.v1"
    private static let playbackCacheKey = "lineup.live-playback-quality.v1"

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
        played = defaults?.data(forKey: Self.playbackCacheKey).flatMap {
            try? JSONDecoder().decode([String: Sample].self, from: $0)
        } ?? [:]
    }

    /// Startup never opens a speculative stream. A real playing input is the
    /// only proof that a URL's measured quality was also playable. This cache
    /// is separate from demux-only probe results from earlier app versions.
    func preferredPlayback(_ candidates: [Candidate], fallback: Int) -> Selection {
        guard !Task.isCancelled else { return Selection(streamID: fallback, wasCancelled: true) }
        let now = Date()
        let fallbackLanguage = candidates.first { $0.id == fallback }?.languageRank ?? 0
        var winner: (selection: Selection, quality: LiveSourceQuality, language: Int)?
        for candidate in candidates where candidate.languageRank <= fallbackLanguage {
            for (index, url) in candidate.urls.enumerated() {
                guard let sample = played[Self.playbackKey(url)], sample.expires > now,
                      let quality = sample.quality, quality.isValid else { continue }
                if winner == nil || candidate.languageRank < winner!.language
                    || (candidate.languageRank == winner!.language && quality.outranks(winner!.quality)) {
                    winner = (Selection(streamID: candidate.id, urlIndex: index, quality: quality), quality, candidate.languageRank)
                }
            }
        }
        return winner?.selection ?? Selection(streamID: fallback)
    }

    func rememberPlayback(url: URL, quality: LiveSourceQuality, now: Date = Date()) {
        guard quality.isValid, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        played = played.filter { $0.value.expires > now }
        let key = Self.playbackKey(url)
        if played[key] == nil, played.count >= 256,
           let oldest = played.min(by: { $0.value.expires < $1.value.expires })?.key { played[oldest] = nil }
        let clean = LiveSourceQuality(width: quality.width, height: quality.height,
            frameRate: quality.frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        played[key] = Sample(quality: clean, expires: now.addingTimeInterval(600))
        if let data = try? JSONEncoder().encode(played) { defaults?.set(data, forKey: Self.playbackCacheKey) }
    }

    private static func playbackKey(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func forgetPlayback(url: URL) {
        guard played.removeValue(forKey: Self.playbackKey(url)) != nil else { return }
        if let data = try? JSONEncoder().encode(played) { defaults?.set(data, forKey: Self.playbackCacheKey) }
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
                    let candidate = candidates[index]
                    var pending = [orders[slot][round]]
                    while !pending.isEmpty {
                        let urlIndex = pending.removeFirst()
                        if samples[index][urlIndex] == nil {
                            let sourceKey = Self.sourceKey(candidate, urlIndex)
                            let sample: Sample
                            if let reused = shared[sourceKey] { sample = reused }
                            else {
                                let remaining = deadline - uptime()
                                if remaining <= 0 { break network }
                                var sourceBudget = Self.perURLBudget
                                #if os(iOS)
                                // HLS needs a playlist and a media read. Give
                                // this selected upgrade a little more of the
                                // SAME overall budget, not another long scan.
                                let knownHeight = samples[index].values.compactMap(\.quality)
                                    .filter(\.isValid).map { min($0.width, $0.height) }.max()
                                if candidate.urls[urlIndex].pathExtension.lowercased() == "m3u8",
                                   let knownHeight, knownHeight < max(1080, candidate.advertisedHeight) {
                                    sourceBudget = 2
                                }
                                #endif
                                let value = try? await probe(candidate.urls[urlIndex], min(sourceBudget, remaining))
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
                        #if os(iOS)
                        // A provider can serve 720p TS and 1080p HLS for the
                        // SAME channel. Round-robin TS reads spent the whole
                        // deadline on other channels before checking that HLS.
                        // Resolve a measured shortfall on this promising feed
                        // first, including a cached partial result. Claims only
                        // schedule a probe; the winning dimensions stay measured.
                        let bestHeight = samples[index].values.compactMap(\.quality)
                            .filter(\.isValid).map { min($0.width, $0.height) }.max()
                        let directTS = candidate.urls[urlIndex].pathExtension.lowercased() == "ts"
                        let target = directTS ? max(1080, candidate.advertisedHeight) : candidate.advertisedHeight
                        if round == 0, let bestHeight, bestHeight < target {
                            let remaining = orders[slot].filter { samples[index][$0] == nil && !pending.contains($0) }
                            pending.append(contentsOf: remaining)
                        }
                        #endif
                    }
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
                    winner = (Selection(streamID: candidate.id, urlIndex: urlIndex, quality: quality), quality, candidate.languageRank)
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

/// Reads metadata from the already-open player only. It cannot open a URL or
/// change engines, transports or the selected channel. Audio-only/undecoded
/// metadata never becomes a playback-confirmed quality measurement.
@MainActor
final class LivePlaybackQualityReporter {
    private let verifier: LiveQualityVerifier
    private var last: (url: URL, quality: LiveSourceQuality, at: Date)?
    init(verifier: LiveQualityVerifier = .shared) { self.verifier = verifier }
    func reset() { last = nil }
    @discardableResult
    func observe(url: URL?, width: Int, height: Int, frameRate: Double?,
                 live: Bool, playing: Bool, picture: Bool) -> Task<Void, Never>? {
        guard live, playing, picture, let url else { return nil }
        let value = LiveSourceQuality(width: width, height: height, frameRate: frameRate)
        guard value.isValid else { return nil }
        let now = Date()
        if let last, last.url == url, last.quality == value, now.timeIntervalSince(last.at) < 300 { return nil }
        last = (url, value, now)
        return Task { await verifier.rememberPlayback(url: url, quality: value, now: now) }
    }
}
