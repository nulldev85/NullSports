import Foundation
import CryptoKit

/// Small derived league facts, not guide listings or playback authorization.
/// Only iOS supplies this cache to its index builder. Exact title/detail
/// fingerprints let unchanged guide channels avoid the measured 16s text scan.
final class SportsIndexFacts: @unchecked Sendable {
    struct Fact: Codable, Sendable {
        let signature: String
        let leagues: Set<SportsLeague>
    }

    private let lock = NSLock()
    private var facts: [String: Fact] = [:]
    private let version: String
    private static let limit = 32_000

    init(version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") {
        // A new app build may change league terms/rosters. Recompute its facts
        // once instead of carrying assumptions across matching-policy changes.
        self.version = "league-facts-v1|" + version
    }

    func leagues(channelID: String, listings: [CurrentProgram], compute: () -> Set<SportsLeague>) -> Set<SportsLeague> {
        let signature = fingerprint(listings)
        lock.lock()
        let known = facts[channelID]
        lock.unlock()
        if known?.signature == signature { return known!.leagues }
        let result = compute()
        lock.lock()
        if facts.count >= Self.limit, facts[channelID] == nil { facts.removeAll(keepingCapacity: true) }
        facts[channelID] = Fact(signature: signature, leagues: result)
        lock.unlock()
        return result
    }

    func restore(_ saved: [String: Fact]) {
        lock.lock()
        facts = saved.count <= Self.limit ? saved : [:]
        lock.unlock()
    }

    func snapshot() -> [String: Fact] {
        lock.lock()
        defer { lock.unlock() }
        return facts
    }

    private func fingerprint(_ listings: [CurrentProgram]) -> String {
        var hash = SHA256()
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            var size = UInt64(bytes.count).littleEndian
            withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        append(version)
        // Times do not affect league classification. Fresh timestamps and
        // full raw listings still go to the matchers and playback revalidation.
        for listing in listings { append(listing.title); append(listing.detail) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
