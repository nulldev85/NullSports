import Foundation

enum MobileGuideViewMode: String, CaseIterable {
    case tvGuide
    case list

    static let storageKey = "Lineup.mobile.guideViewMode.v1"
    static let defaultMode: Self = .tvGuide

    var title: String {
        switch self {
        case .tvGuide: "TV Guide"
        case .list: "List"
        }
    }

    var symbol: String {
        switch self {
        case .tvGuide: "rectangle.grid.1x2"
        case .list: "list.bullet"
        }
    }

    static func restored(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? defaultMode
    }
}
