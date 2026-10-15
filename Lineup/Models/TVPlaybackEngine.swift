#if os(tvOS)
import Foundation

enum TVPlaybackEngine: String, CaseIterable, Identifiable, Sendable {
    case vlc, aether
    static let storageKey = "Lineup.tv.playbackEngine.v1"
    var id: String { rawValue }
    var title: String { self == .vlc ? "VLC" : "AetherEngine" }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .vlc
    }
}
#endif
