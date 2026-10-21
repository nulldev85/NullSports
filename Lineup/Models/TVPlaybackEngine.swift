#if os(tvOS)
import Foundation

enum TVPlaybackEngine: String, CaseIterable, Identifiable, Sendable {
    case vlc, aether, mpv
    static let storageKey = "Lineup.tv.playbackEngine.v1"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vlc: "VLC"
        case .aether: "AetherEngine"
        case .mpv: "MPVKit (Trial)"
        }
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .vlc
    }
}
#endif
