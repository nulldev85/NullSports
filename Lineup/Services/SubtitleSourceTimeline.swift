import Foundation

/// Convert a source-timed SubRip sidecar to a remux's local player clock.
/// Original bytes are retained separately so every new plan can rebase them.
enum SubtitleSourceTimeline {
    static func rebase(_ data: Data, offset: Double) throws -> Data {
        guard offset.isFinite, offset >= 0, offset < 1_000_000_000,
              let text = String(data: data, encoding: .utf8) else { throw MobileSubtitleFailure.invalidFile }
        if offset == 0 { return data }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let expression = try NSRegularExpression(pattern: #"^(\d{1,4}):([0-5]\d):([0-5]\d)[,.](\d{3})\s*-->\s*(\d{1,4}):([0-5]\d):([0-5]\d)[,.](\d{3})(.*)$"#)
        var cues: [String] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let line = lines[index]
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { throw MobileSubtitleFailure.invalidFile }
            func time(_ group: Int) throws -> Double {
                let values = try (group..<(group + 4)).map { position -> Double in
                    guard let range = Range(match.range(at: position), in: line), let value = Double(line[range]) else { throw MobileSubtitleFailure.invalidFile }
                    return value
                }
                return values[0] * 3600 + values[1] * 60 + values[2] + values[3] / 1000
            }
            let start = try time(1) - offset, end = try time(5) - offset
            guard end > 0 else { continue }
            guard end > start else { throw MobileSubtitleFailure.invalidFile }
            let suffix = Range(match.range(at: 9), in: line).map { String(line[$0]) } ?? ""
            let content = lines.dropFirst(index + 1).joined(separator: "\n").trimmingCharacters(in: .newlines)
            cues.append("\(cues.count + 1)\n\(timestamp(max(0, start))) --> \(timestamp(end))\(suffix)\n\(content)")
        }
        // A seek beyond the last caption has no visible cues. Retain a valid
        // empty sidecar rather than replaying captions from the source's start.
        if cues.isEmpty { return Data("1\n00:00:00,000 --> 00:00:00,001\n\u{200B}\n".utf8) }
        return Data((cues.joined(separator: "\n\n") + "\n").utf8)
    }
    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int64((seconds * 1000).rounded())
        return String(format: "%02lld:%02lld:%02lld,%03lld", milliseconds / 3_600_000,
            milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
