import Foundation

/// HTTP suffix ranges name a byte count at the END, not an end offset.
/// Aether uses these to prefetch MKV indexes before resuming playback.
enum PlaybackFixtureByteRange {
    static func resolve(_ header: String?, count: Int) -> Range<Int>? {
        guard count > 0 else { return nil }
        guard let header else { return 0..<count }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        func number(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(text)
        }
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]), suffix > 0 else { return nil }
            return (count - min(suffix, count))..<count
        }
        guard let start = number(parts[0]), start < count else { return nil }
        if parts[1].isEmpty { return start..<count }
        guard let end = number(parts[1]), end >= start else { return nil }
        return start..<(min(end, count - 1) + 1)
    }
}
