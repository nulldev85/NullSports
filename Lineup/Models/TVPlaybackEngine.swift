#if os(tvOS)
import Foundation

enum TVPlaybackEngine: String, CaseIterable, Identifiable, Sendable {
    case vlc, aether
    static let storageKey = "Lineup.tv.playbackEngine.v1"
    var id: String { rawValue }
    var title: String { self == .vlc ? "VLC" : "AetherEngine" }
    /// The engine's own logo in the asset catalog.
    var logo: String { self == .vlc ? "Engine-vlc" : "Engine-aether" }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .vlc
    }
}
#endif
