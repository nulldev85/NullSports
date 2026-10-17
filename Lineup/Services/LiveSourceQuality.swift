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

/// Serializes preflights across both screens and repeated taps. Waiting for a
/// cancelled probe to close is deliberate: the next probe must not overlap it.
actor LiveQualityVerifier {
    static let shared = LiveQualityVerifier()
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
    }
    struct Selection: Equatable, Sendable {
        let streamID: Int
        var urlIndex: Int? = nil
    }
    typealias Probe = @Sendable (URL, TimeInterval) async throws -> LiveSourceQuality
    private let probe: Probe
    private let defaults: UserDefaults?
    private var cache: [String: Entry]
    private var tail: Task<Void, Never>?
    private static let cacheKey = "lineup.live-source-quality.v1"

    init(defaults: UserDefaults? = .standard, probe: @escaping Probe = { url, timeout in
        let result = try await AetherSourceProbe.quality(url: url, timeout: timeout)
        return LiveSourceQuality(width: result.width, height: result.height, frameRate: result.frameRate)
    }) {
        self.defaults = defaults
        self.probe = probe
        cache = defaults?.data(forKey: Self.cacheKey).flatMap {
            try? JSONDecoder().decode([String: Entry].self, from: $0)
        } ?? [:]
    }

    static func key(_ candidate: Candidate) -> String {
        // Neither credential-bearing URLs nor provider/event names go to disk.
        SHA256.hash(data: Data(([candidate.context, String(candidate.id)] + candidate.urls.map(\.absoluteString))
            .joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func best(_ candidates: [Candidate], fallback fallbackID: Int, budget: TimeInterval = 30) async -> Selection {
        let fallback = Selection(streamID: fallbackID)
        let previous = tail
        let work = Task { [weak self] () -> Selection in
            await previous?.value
            guard !Task.isCancelled, let self else { return fallback }
            return await self.measure(candidates, fallback: fallback, budget: budget)
        }
        tail = Task { _ = await work.value }
        return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    private func measure(_ candidates: [Candidate], fallback: Selection, budget: TimeInterval) async -> Selection {
        let clock = ContinuousClock()
        let start = clock.now
        var winner: (Selection, LiveSourceQuality, Int)?
        for candidate in candidates {
            if Task.isCancelled { return fallback }
            let key = Self.key(candidate)
            var quality: LiveSourceQuality?
            var urlIndex: Int?
            if let saved = cache[key], saved.expires > Date(),
               saved.quality == nil || saved.urlIndex.map({ candidate.urls.indices.contains($0) }) == true {
                quality = saved.quality.flatMap { $0.isValid ? $0 : nil }
                urlIndex = saved.urlIndex.flatMap { candidate.urls.indices.contains($0) ? $0 : nil }
            } else {
                if start.duration(to: clock.now) >= .seconds(budget) { break }
                for (index, url) in candidate.urls.enumerated() {
                    let elapsed = start.duration(to: clock.now)
                    let spent = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    let remaining = budget - spent
                    if remaining <= 0 || Task.isCancelled { break }
                    if let measured = try? await probe(url, min(5, remaining)), measured.isValid {
                        if quality == nil || measured.outranks(quality!) {
                            quality = measured
                            urlIndex = index
                        }
                    }
                }
                guard !Task.isCancelled else { return fallback }
                // Failure is not a low-resolution measurement. Briefly cache
                // it to avoid hammering an unavailable provider on every tap.
                cache[key] = Entry(quality: quality, expires: Date().addingTimeInterval(quality == nil ? 30 : 600), urlIndex: urlIndex)
            }
            if let quality {
                if winner == nil || candidate.languageRank < winner!.2
                    || (candidate.languageRank == winner!.2 && quality.outranks(winner!.1)) {
                    winner = (Selection(streamID: candidate.id, urlIndex: urlIndex), quality, candidate.languageRank)
                }
            }
        }
        cache = cache.filter { $0.value.expires > Date() }
        if let data = try? JSONEncoder().encode(cache) { defaults?.set(data, forKey: Self.cacheKey) }
        return winner?.0 ?? fallback
    }
}
