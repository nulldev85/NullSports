import Foundation
import SwiftUI

struct XtreamProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var serverURL: String
    var username: String

    init(id: UUID = UUID(), name: String, serverURL: String, username: String) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
    }
}

struct XtreamCategory: Codable, Identifiable, Hashable {
    let categoryID: String
    let categoryName: String

    var id: String { categoryID }

    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
    }
}

struct XtreamStream: Codable, Identifiable, Hashable {
    let num: Int?
    let name: String
    let streamType: String?
    let streamID: Int
    let streamIcon: String?
    let epgChannelID: String?
    let categoryID: String?

    var id: Int { streamID }

    enum CodingKeys: String, CodingKey {
        case num, name
        case streamType = "stream_type"
        case streamID = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelID = "epg_channel_id"
        case categoryID = "category_id"
    }
}

struct XtreamEnvelope: Codable {
    struct UserInfo: Codable {
        let auth: Int?
        let status: String?
        let expDate: String?
        let maxConnections: String?

        enum CodingKeys: String, CodingKey {
            case auth, status
            case expDate = "exp_date"
            case maxConnections = "max_connections"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? values.decode(Int.self, forKey: .auth) {
                auth = number
            } else if let text = try? values.decode(String.self, forKey: .auth) {
                auth = Int(text)
            } else {
                auth = nil
            }
            status = try? values.decode(String.self, forKey: .status)
            expDate = try? values.decode(String.self, forKey: .expDate)
            maxConnections = try? values.decode(String.self, forKey: .maxConnections)
        }
    }

    let userInfo: UserInfo?

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
    }
}

enum SportsLeague: String, CaseIterable, Identifiable {
    case nfl, nba, nhl, mlb

    var id: String { rawValue }
    var shortName: String { rawValue.uppercased() }
    var fullName: String {
        switch self {
        case .nfl: "Football"
        case .nba: "Basketball"
        case .nhl: "Hockey"
        case .mlb: "Baseball"
        }
    }
    var color: Color {
        switch self {
        case .nfl: Color(red: 0.61, green: 0.43, blue: 0.31)
        case .nba: Color(red: 0.70, green: 0.39, blue: 0.28)
        case .nhl: Color(red: 0.45, green: 0.55, blue: 0.59)
        case .mlb: Color(red: 0.42, green: 0.49, blue: 0.66)
        }
    }

    func matches(_ text: String) -> Bool {
        let value = text.lowercased()
        return switch self {
        case .nfl: value.contains("nfl") || value.contains("football")
        case .nba: value.contains("nba") || value.contains("basketball")
        case .nhl: value.contains("nhl") || value.contains("hockey")
        case .mlb: value.contains("mlb") || value.contains("baseball")
        }
    }
}
