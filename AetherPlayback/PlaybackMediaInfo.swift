import Foundation

/// Attributes of the selected source streams, not the screen/speaker output
/// capability and never a guess from a channel or release name.
public struct PlaybackMediaInfo: Equatable, Hashable, Sendable {
    public var dynamicRange: String?
    public var videoCodec: String?
    public var frameRate: Double?
    public var audioCodec: String?
    public var audioProfile: String?
    public var audioChannels: Int?
    public var audioLayout: String?
    public var isDolbyAtmos: Bool

    public init(dynamicRange: String? = nil, videoCodec: String? = nil, frameRate: Double? = nil,
                audioCodec: String? = nil, audioProfile: String? = nil,
                audioChannels: Int? = nil, audioLayout: String? = nil,
                isDolbyAtmos: Bool = false) {
        self.dynamicRange = dynamicRange
        self.videoCodec = videoCodec
        self.frameRate = frameRate.flatMap { $0.isFinite && $0 > 0 && $0 <= 360 ? $0 : nil }
        self.audioCodec = audioCodec
        self.audioProfile = audioProfile
        self.audioChannels = audioChannels.flatMap { $0 > 0 && $0 <= 64 ? $0 : nil }
        self.audioLayout = audioLayout
        // Aether's isAtmos flag covers E-AC-3 JOC; its decoder-confirmed
        // TrueHD Atmos identity is published separately as a track profile.
        self.isDolbyAtmos = isDolbyAtmos || (audioCodec?.lowercased() == "truehd"
            && audioProfile?.lowercased() == "dolby truehd + dolby atmos")
    }

    public var badges: [String] {
        var result: [String] = []
        if let dynamicRange { result.append(dynamicRange) }
        if isDolbyAtmos { result.append("Dolby Atmos") }
        else if let audio = Self.audioLabel(audioCodec, profile: audioProfile) { result.append(audio) }
        if let layout = channelLabel, !isDolbyAtmos { result.append(layout) }
        if let video = Self.videoLabel(videoCodec) { result.append(video) }
        if let rate = frameRate, rate.isFinite, rate > 0, rate <= 360 {
            var value = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), rate)
            while value.last == "0" { value.removeLast() }
            if value.last == "." { value.removeLast() }
            result.append(value + " fps")
        }
        return result
    }

    private var channelLabel: String? {
        // A channel count alone does not establish a subwoofer channel.
        // Keep 6.0 distinct from 5.1 and don't call eight channels Atmos.
        if let layout = audioLayout?.lowercased() {
            if ["5.1", "5.1(side)", "5.1(back)"].contains(layout) { return "5.1" }
            if ["7.1", "7.1(wide)", "7.1(wide-side)"].contains(layout) { return "7.1" }
        }
        switch audioChannels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case let count? where count > 2: return "\(count) ch"
        default: return nil
        }
    }

    public static func videoLabel(_ codec: String?) -> String? {
        switch codec?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "h264", "avc1", "avc3", "dvav", "dva1": return "H.264"
        case "hevc", "h265", "hvc1", "hev1", "dvh1", "dvhe": return "HEVC"
        case "av1", "av01", "dav1": return "AV1"
        case "vp9", "vp09": return "VP9"
        case "mpeg2video", "mpgv", "mp2v": return "MPEG-2"
        case "mpeg4", "mp4v": return "MPEG-4"
        default: return nil
        }
    }

    public static func audioLabel(_ codec: String?, profile: String? = nil) -> String? {
        switch codec?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "aac", "mp4a", "aach", "aacl", "aace", "aacp": return "AAC"
        case "ac3", "ac-3", "a52": return "Dolby Digital"
        case "eac3", "ec-3", "ec+3", "e-ac-3": return "Dolby Digital Plus"
        case "truehd": return "Dolby TrueHD"
        case "mlp": return "MLP"
        case "dts", "dca", "dtsc", "dtsh", "dtsl":
            switch profile?.lowercased() {
            case "dts-hd ma + dts:x", "dts-hd ma + dts:x imax": return "DTS:X"
            case "dts-hd ma": return "DTS-HD MA"
            case "dts-hd hra": return "DTS-HD HRA"
            default: return "DTS"
            }
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "mp3", ".mp3": return "MP3"
        case "mp2", "mp2a", ".mp2": return "MP2"
        case "mpga": return "MPEG Audio"
        case "pcm", "lpcm", "araw": return "PCM"
        default: return nil
        }
    }

    /// ISO/IEC 14496-12 / ETSI TS 102 366 Annex F. E-AC-3 alone is
    /// insufficient: the dec3 extension_type_a flag confirms JOC (Atmos).
    public static func carriesDolbyAtmos(dec3 data: Data) -> Bool {
        guard data.count <= 4096 else { return false }
        var bytes = Array(data)
        var bit = 0
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("dec3".utf8) {
            let length = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard Int(length) == bytes.count else { return false }
            bytes.removeFirst(8)
        }
        func read(_ count: Int) -> Int? {
            guard count >= 0, bit <= bytes.count * 8 - count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[bit / 8] >> (7 - bit % 8)) & 1)
                bit += 1
            }
            return value
        }
        guard read(13) != nil, let independent = read(3) else { return false }
        for _ in 0...independent {
            guard read(2) != nil, let bitstreamID = read(5), (11...16).contains(bitstreamID),
                  read(12) != nil, let dependent = read(4),
                  read(dependent > 0 ? 9 : 1) != nil else { return false }
        }
        guard read(7) != nil, read(1) == 1, read(8) != nil else { return false }
        return true
    }
}
