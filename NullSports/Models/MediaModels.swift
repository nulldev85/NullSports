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

    var quality: String? {
        let value = releaseName.lowercased()
        if value.contains("2160p") || value.contains("4k") { return "4K" }
        if value.contains("1080p") { return "1080p" }
        if value.contains("720p") { return "720p" }
        if value.contains("480p") { return "480p" }
        return nil
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
