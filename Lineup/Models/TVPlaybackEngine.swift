#if os(tvOS)
import Foundation

enum TVPlaybackEngine: String, CaseIterable, Identifiable, Sendable {
    case vlc, aether
    /// The one engine every tab used before each tab had its own, and still
    /// the engine of a tab that has not been given one.
    static let storageKey = "Lineup.tv.playbackEngine.v1"
    var id: String { rawValue }
    var title: String { self == .vlc ? "VLC" : "AetherEngine" }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .vlc
    }

    /// The engine a tab plays with: its own choice, or until it has one, the
    /// engine chosen for every tab.
    static func selected(for place: TVPlaybackPlace?, in defaults: UserDefaults = .standard) -> Self {
        if let place, let own = defaults.string(forKey: place.storageKey).flatMap(Self.init(rawValue:)) {
            return own
        }
        return selected(in: defaults)
    }
}

/// The tabs that play video, each of which keeps its own playback engine:
/// a server's heavy files can play best on one engine and live TV on the other.
enum TVPlaybackPlace: String, CaseIterable, Identifiable, Sendable {
    case sports, guide, library, search
    var id: String { rawValue }
    var storageKey: String { "Lineup.tv.playbackEngine.\(rawValue).v1" }

    var title: String {
        switch self {
        case .sports: "Sports"
        case .guide: "TV Guide"
        case .library: "Library"
        case .search: "Search"
        }
    }

    /// What plays there, for its row in Settings.
    var detail: String {
        switch self {
        case .sports: "Games, previews and Multiview"
        case .guide: "Channels, previews and catch-up"
        case .library: "Movies and shows, from your servers and VOD"
        case .search: "Channels and titles opened from Search"
        }
    }

    var symbol: String {
        switch self {
        case .sports: "sportscourt"
        case .guide: "list.bullet.rectangle"
        case .library: "play.square.stack"
        case .search: "magnifyingglass"
        }
    }
}
#endif
