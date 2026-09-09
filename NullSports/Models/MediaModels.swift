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
