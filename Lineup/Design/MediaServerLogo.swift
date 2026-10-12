import SwiftUI

/// Which media server software a server is, for the mark shown beside its
/// name.
///
/// Every server Lineup connects to today speaks Jellyfin -- Jellyfin itself,
/// and the servers built on its API -- so there is one case. Plex and Emby
/// each become a case here, with their own mark in `MediaServerLogo`, when
/// Lineup can connect to them.
enum MediaServerBrand: Sendable, Equatable {
    case jellyfin

    static func of(_ profile: MediaServerProfile) -> MediaServerBrand { .jellyfin }

    /// The brand every one of these servers shares, or nil when they differ.
    static func shared(by profiles: [MediaServerProfile]) -> MediaServerBrand? {
        let brands = profiles.map(of)
        guard let first = brands.first, brands.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    var name: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        }
    }
}

/// A server software's mark, in its own colours, sized to fit the frame it is
/// given.
struct MediaServerLogo: View {
    let brand: MediaServerBrand

    var body: some View {
        switch brand {
        case .jellyfin:
            JellyfinMark()
                .fill(LinearGradient(colors: [Color(red: 0xAA / 255, green: 0x5C / 255, blue: 0xC3 / 255),
                                              Color(red: 0x00 / 255, green: 0xA4 / 255, blue: 0xDC / 255)],
                                     startPoint: UnitPoint(x: 110.25 / 512, y: 213.3 / 512),
                                     endPoint: UnitPoint(x: 496.14 / 512, y: 436.09 / 512)),
                      style: FillStyle(eoFill: true))
                .aspectRatio(1, contentMode: .fit)
                .accessibilityLabel(brand.name)
        }
    }
}

/// Jellyfin's mark: a rounded triangle with a smaller one inside it.
///
/// Drawn from the path in Jellyfin's own artwork (jellyfin-ux,
/// branding/SVG/icon-transparent.svg, CC BY-SA 4.0, by the Jellyfin
/// contributors), on its 512-point square. The outer shape's opening and the
/// inner triangle are one path filled even-odd, as the artwork's two paths
/// draw them.
private struct JellyfinMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 512
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        // The inner triangle.
        path.move(to: p(256, 201.6))
        path.addCurve(to: p(179.8, 341), control1: p(235.6, 201.6), control2: p(169.8, 320.9))
        path.addCurve(to: p(332.2, 341), control1: p(189.8, 361.1), control2: p(322.3, 360.9))
        path.addCurve(to: p(256, 201.6), control1: p(342.1, 321.1), control2: p(276.5, 201.6))
        path.closeSubpath()
        // The outer triangle.
        path.move(to: p(256, 23.3))
        path.addCurve(to: p(26.4, 443.4), control1: p(194.4, 23.3), control2: p(-3.8, 382.7))
        path.addCurve(to: p(485.6, 443.4), control1: p(56.6, 504.1), control2: p(455.7, 503.4))
        path.addCurve(to: p(256, 23.3), control1: p(515.5, 383.4), control2: p(317.6, 23.3))
        path.closeSubpath()
        // The opening in it.
        path.move(to: p(406.5, 390.8))
        path.addCurve(to: p(105.6, 390.8), control1: p(386.9, 430.1), control2: p(125.4, 430.6))
        path.addCurve(to: p(256, 115.5), control1: p(85.8, 351), control2: p(215.7, 115.5))
        path.addCurve(to: p(406.5, 390.8), control1: p(296.3, 115.5), control2: p(426.1, 351.4))
        path.closeSubpath()
        return path
    }
}
