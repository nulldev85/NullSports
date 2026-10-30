import Foundation

/// Provider-advertised resolution/rate, not measured bitrate or an HDR claim.
/// Unknown labels, codecs, "RAW" and marketing words confer no quality rank.
struct LiveChannelQuality: Codable, Equatable, Comparable, Sendable {
    let height: Int
    let frameRate: Int
    private let resolutionLabel: String?
    static let unknown = Self(height: 0, frameRate: 0)

    init(height: Int, frameRate: Int) {
        self.height = height; self.frameRate = frameRate
        self.resolutionLabel = Self.numericLabel(height)
    }

    init(name: String) {
        let text = name.lowercased()
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var height = 0, rate = 0
        var label: String?
        for token in tokens {
            let numeric = token.first?.isNumber == true
            if numeric, token.contains("p"), let match = Self.match(Self.resolution, token), let value = Int(match[1]),
               Self.heights.contains(value) {
                if value >= height { height = value; label = Self.numericLabel(value) }
                if let fps = Int(match[2]), Self.rates.contains(fps) { rate = max(rate, fps) }
            }
            if let value = Self.labels[token], value > height { height = value; label = token.uppercased() }
            let combined = token.hasPrefix("4k") || token.hasPrefix("8k") || token.hasPrefix("uhd")
                || token.hasPrefix("fhd") || token.hasPrefix("hd")
            if combined, let match = Self.match(Self.combined, token), let value = Self.labels[match[1]], let fps = Int(match[2]) {
                if value > height { height = value; label = match[1].uppercased() }
                rate = max(rate, fps)
            }
            if numeric, token.hasSuffix("fps") || token.hasSuffix("hz"),
               let match = Self.match(Self.fps, token), let fps = Int(match[1]) { rate = max(rate, fps) }
        }
        if height < 1080, text.contains("full"),
           text.range(of: #"\bfull[\s_-]+hd\b"#, options: .regularExpression) != nil {
            height = 1080; label = "Full HD"
        }
        if text.contains(" fps") || text.contains(" hz"),
           let match = Self.match(Self.spacedFPS, text), let fps = Int(match[1]) { rate = max(rate, fps) }
        self.height = height
        self.frameRate = rate
        self.resolutionLabel = label
    }

    var label: String? {
        let parts = [resolutionLabel, frameRate > 0 ? "\(frameRate) fps" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.height == rhs.height && lhs.frameRate == rhs.frameRate }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.height != rhs.height ? lhs.height < rhs.height : lhs.frameRate < rhs.frameRate
    }

    private static let rates: Set<Int> = [24, 25, 30, 50, 60, 120]
    private static let heights: Set<Int> = [360, 480, 540, 576, 720, 1080, 1440, 2160, 4320]
    private static let labels = ["8k": 4320, "4k": 2160, "uhd": 2160, "fhd": 1080, "fullhd": 1080, "hd": 720, "sd": 480]
    private static let resolution = try! NSRegularExpression(pattern: #"^(\d{3,4})p(\d{2,3})?$"#)
    private static let combined = try! NSRegularExpression(pattern: #"^(8k|4k|uhd|fhd|hd)(24|25|30|50|60|120)$"#)
    private static let fps = try! NSRegularExpression(pattern: #"^(24|25|30|50|60|120)(?:fps|hz)$"#)
    private static let spacedFPS = try! NSRegularExpression(pattern: #"(?:^|[^a-z0-9])(24|25|30|50|60|120)\s+(?:fps|hz)(?:$|[^a-z0-9])"#)
    private static func numericLabel(_ height: Int) -> String? {
        switch height {
        case 4320: "8K"
        case 2160: "4K"
        case 0: nil
        default: "\(height)p"
        }
    }
    private static func match(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
