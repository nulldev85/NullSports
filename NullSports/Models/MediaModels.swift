import Foundation

struct MediaServerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var serverURL: String
    var username: String
    var userID: String

    init(id: UUID = UUID(), name: String, serverURL: String, username: String, userID: String) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.userID = userID
    }
}

struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let overview: String?
    let productionYear: Int?
    let primaryImageAspectRatio: Double?
    let childCount: Int?

    var isPlayable: Bool {
        ["Movie", "Episode", "Video"].contains(type)
    }

    var isFolder: Bool { !isPlayable }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case childCount = "ChildCount"
    }
}

struct MediaCatalog: Identifiable, Hashable, Sendable {
    let root: MediaItem
    let items: [MediaItem]
    var id: String { root.id }
    var title: String { root.name }
}

struct JellyfinItemsResponse: Codable, Sendable {
    let items: [MediaItem]

    enum CodingKeys: String, CodingKey { case items = "Items" }
}

struct JellyfinAuthenticationResponse: Codable, Sendable {
    struct User: Codable, Sendable { let id: String; let name: String
        enum CodingKeys: String, CodingKey { case id = "Id"; case name = "Name" }
    }
    let user: User
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
    }
}

struct MediaPlaybackInfo: Decodable, Sendable {
    let mediaSources: [MediaPlaybackSource]

    enum CodingKeys: String, CodingKey { case mediaSources = "MediaSources" }
}

struct MediaPlaybackSource: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let bitrate: Int64?
    let remux: RemuxInfo?

    struct RemuxInfo: Decodable, Hashable, Sendable {
        let providerInfo: ProviderInfo?
        enum CodingKeys: String, CodingKey { case providerInfo = "ProviderInfo" }
    }

    struct ProviderInfo: Decodable, Hashable, Sendable {
        let source: String?
        let filename: String?
        let description: String?
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case remux = "Remux"
    }

    var displayLines: [String] {
        (name ?? remux?.providerInfo?.description ?? "Stream")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var provider: String {
        remux?.providerInfo?.source ?? displayLines.first ?? "Media Server"
    }

    var releaseName: String {
        if let filename = remux?.providerInfo?.filename {
            return filename.replacingOccurrences(of: #"^🎯 SCORE [+-]?\d+ 🎯 •\s*"#,
                with: "", options: .regularExpression)
        }
        return displayLines.dropFirst(2).first ?? displayLines.dropFirst().first ?? "Available stream"
    }

    var score: Int? {
        let text = [name, remux?.providerInfo?.filename, remux?.providerInfo?.description]
            .compactMap { $0 }.joined(separator: " ")
        guard let match = text.range(of: #"(?i)score[: ]+([+-]?\d+)"#, options: .regularExpression) else { return nil }
        let value = text[match].replacingOccurrences(of: #"(?i)score[: ]+"#, with: "", options: .regularExpression)
        return Int(value)
    }

    // A release name and the server's own probe line describe the same stream in
    // different words: one says "H 265", the other "hevc". Reading both means a
    // detail shows up whichever of them happens to carry it.
    private var descriptorText: String {
        [releaseName, name, remux?.providerInfo?.filename, remux?.providerInfo?.description]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }

    // Separators are the only difference between "H.265", "H 265" and "H265",
    // so most of these tokens are easier to find with them gone.
    private var condensedDescriptor: String {
        descriptorText.replacingOccurrences(of: #"[ ._-]"#, with: "", options: .regularExpression)
    }

    var quality: String? {
        let value = descriptorText
        if value.contains("2160p") || value.contains("4k") || value.contains("uhd") { return "4K" }
        if value.contains("1440p") { return "1440p" }
        if value.contains("1080p") { return "1080p" }
        if value.contains("720p") { return "720p" }
        if value.contains("480p") { return "480p" }
        return nil
    }

    // A hybrid release carries both, and which one a TV can use depends on the TV,
    // so both are worth naming rather than picking one.
    var dynamicRangeTags: [String] {
        var tags: [String] = []
        let condensed = condensedDescriptor
        if condensed.contains("dolbyvision") || condensed.contains("dovi")
            || descriptorText.range(of: #"\bdv\b"#, options: .regularExpression) != nil {
            tags.append("DV")
        }
        if condensed.contains("hdr10plus") || condensed.contains("hdr10+") { tags.append("HDR10+") }
        else if condensed.contains("hdr10") { tags.append("HDR10") }
        else if condensed.contains("hdr") { tags.append("HDR") }
        return tags
    }

    var videoCodec: String? {
        let condensed = condensedDescriptor
        if condensed.contains("av1") { return "AV1" }
        if condensed.contains("hevc") || condensed.contains("h265") || condensed.contains("x265") { return "H.265" }
        if condensed.contains("h264") || condensed.contains("x264") || condensed.contains("avc") { return "H.264" }
        if condensed.contains("mpeg2") { return "MPEG-2" }
        return nil
    }

    var bitDepth: String? {
        let condensed = condensedDescriptor
        if condensed.contains("10bit") { return "10-bit" }
        if condensed.contains("8bit") { return "8-bit" }
        return nil
    }

    var audioCodec: String? {
        let condensed = condensedDescriptor
        if condensed.contains("truehd") { return "TrueHD" }
        if condensed.contains("dtsx") { return "DTS:X" }
        if condensed.contains("dtshd") { return "DTS-HD" }
        if condensed.contains("dts") { return "DTS" }
        if condensed.contains("eac3") || condensed.contains("ddp") || condensed.contains("dd+") { return "DD+" }
        if condensed.contains("ac3") { return "DD" }
        if condensed.contains("flac") { return "FLAC" }
        if condensed.contains("aac") { return "AAC" }
        if condensed.contains("opus") { return "Opus" }
        return nil
    }

    var hasAtmos: Bool { condensedDescriptor.contains("atmos") }

    // Channel counts are written "5.1" and "DDP5 1" alike. Bounding the digits
    // keeps a year or a score from reading as a surround layout.
    var audioChannels: String? {
        let text = descriptorText
        guard let range = text.range(of: #"(?<![0-9])[2567][. ][01](?![0-9])"#,
            options: .regularExpression) else { return nil }
        return text[range].replacingOccurrences(of: " ", with: ".")
    }

    var sourceTag: String? {
        let condensed = condensedDescriptor
        if condensed.contains("remux") { return "REMUX" }
        if condensed.contains("bluray") || condensed.contains("bdrip") || condensed.contains("brrip") { return "BluRay" }
        if condensed.contains("webdl") { return "WEB-DL" }
        if condensed.contains("webrip") { return "WEBRip" }
        if condensed.contains("hdtv") { return "HDTV" }
        if condensed.contains("dvdrip") { return "DVD" }
        return nil
    }

    // The server's search line reads "\u{1F50D} StreamNZB Library - altHUB \u{2022} \u{1F3AF} Score: +70494".
    // Only the tail names the indexer; the rest repeats the addon shown beside it.
    var indexer: String? {
        guard let line = displayLines.first(where: { $0.contains("\u{1F50D}") }) else { return nil }
        let head = line.split(separator: Character("\u{2022}")).first.map(String.init) ?? line
        let cleaned = head.replacingOccurrences(of: "\u{1F50D}", with: "")
            .trimmingCharacters(in: .whitespaces)
        let name = cleaned.components(separatedBy: " - ").last?
            .trimmingCharacters(in: .whitespaces) ?? cleaned
        guard !name.isEmpty, name.caseInsensitiveCompare(provider) != .orderedSame else { return nil }
        return name
    }

    // Ordered the way a stream is judged: how it looks, then how it sounds, then
    // where it was mastered from.
    var badges: [String] {
        var badges = dynamicRangeTags
        if let videoCodec { badges.append(videoCodec) }
        if let bitDepth { badges.append(bitDepth) }
        if let audioCodec { badges.append(audioCodec) }
        if hasAtmos { badges.append("Atmos") }
        if let audioChannels { badges.append(audioChannels) }
        if let sourceTag { badges.append(sourceTag) }
        return badges
    }

    // The measurable facts, in the order someone compares two results by.
    var facts: [String] {
        [formattedSize, formattedBitrate, containerLabel, indexer].compactMap { $0 }
    }

    // Servers name containers in full, and "MATROSKA" costs the width of the
    // numbers beside it for no more meaning than "MKV".
    var containerLabel: String? {
        guard let first = container?.split(separator: ",").first else { return nil }
        let value = first.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        switch value {
        case "matroska": return "MKV"
        case "quicktime", "mpeg-4": return "MP4"
        default: return value.uppercased()
        }
    }

    var formattedSize: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // Servers report bits per second. Mbps is how a release is usually described,
    // and one decimal separates neighbouring encodes without adding noise.
    var formattedBitrate: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        let mbps = Double(bitrate) / 1_000_000
        return mbps >= 10 ? "\(Int(mbps.rounded())) Mbps" : String(format: "%.1f Mbps", mbps)
    }
}
