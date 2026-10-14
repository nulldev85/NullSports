import SwiftUI

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
        case .emby:
            EmbyMark()
                .fill(Color(red: 0x52 / 255, green: 0xB5 / 255, blue: 0x4B / 255), style: FillStyle(eoFill: true))
                .aspectRatio(1, contentMode: .fit)
                .accessibilityLabel(brand.name)
        case .plex:
            // Plex's own app mark: its chevron, gold on black.
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255))
                    .overlay {
                        PlexChevron()
                            .fill(Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255))
                            .padding(side * 0.2)
                    }
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel(brand.name)
        }
    }
}

/// Every kind of server Lineup connects to, side by side: where adding one is
/// offered before it is known which.
struct MediaServerLogoRow: View {
    var size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.35) {
            ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                MediaServerLogo(brand: brand).frame(width: size, height: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jellyfin, Emby or Plex")
    }
}

/// Emby's mark: a rounded diamond with a play triangle cut from it.
///
/// Drawn from Simple Icons' Emby path (simple-icons, icons/emby.svg, CC0),
/// on its 24-point square, its two near-straight arcs as the lines they are.
private struct EmbyMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        path.move(to: p(11.04, 0))
        path.addCurve(to: p(7.82, 3.18), control1: p(11.03, 0), control2: p(9.59, 1.43))
        path.addLine(to: p(4.62, 6.35))
        path.addLine(to: p(5.13, 6.87))
        path.addLine(to: p(5.64, 7.38))
        path.addLine(to: p(2.82, 10.17))
        path.addLine(to: p(0, 12.96))
        path.addLine(to: p(1.83, 14.81))
        path.addCurve(to: p(5.01, 18.02), control1: p(2.84, 15.83), control2: p(4.27, 17.27))
        path.addLine(to: p(6.36, 19.38))
        path.addLine(to: p(6.87, 18.88))
        path.addCurve(to: p(7.4, 18.38), control1: p(7.15, 18.61), control2: p(7.39, 18.38))
        path.addCurve(to: p(10.19, 21.19), control1: p(7.4, 18.38), control2: p(8.66, 19.65))
        path.addLine(to: p(12.97, 24))
        path.addLine(to: p(13.16, 23.82))
        path.addCurve(to: p(18.87, 18.16), control1: p(13.39, 23.59), control2: p(18.16, 18.87))
        path.addLine(to: p(19.39, 17.65))
        path.addLine(to: p(18.89, 17.13))
        path.addCurve(to: p(18.4, 16.6), control1: p(18.62, 16.85), control2: p(18.39, 16.61))
        path.addCurve(to: p(21.2, 13.82), control1: p(18.4, 16.59), control2: p(19.66, 15.34))
        path.addCurve(to: p(24, 11.03), control1: p(22.74, 12.3), control2: p(24, 11.04))
        path.addCurve(to: p(17.89, 4.84), control1: p(24.01, 11.02), control2: p(20.38, 7.35))
        path.addLine(to: p(17.65, 4.6))
        path.addLine(to: p(17.14, 5.1))
        path.addCurve(to: p(16.61, 5.6), control1: p(16.87, 5.38), control2: p(16.63, 5.61))
        path.addCurve(to: p(13.82, 2.8), control1: p(16.6, 5.6), control2: p(15.34, 4.33))
        path.addLine(to: p(11.04, 0))
        path.closeSubpath()
        // The play triangle.
        path.move(to: p(9.22, 7.37))
        path.addCurve(to: p(17.18, 11.99), control1: p(9.31, 7.41), control2: p(17.17, 11.97))
        path.addCurve(to: p(13.21, 14.31), control1: p(17.18, 12.01), control2: p(15.4, 13.05))
        path.addLine(to: p(9.22, 16.62))
        path.addCurve(to: p(9.19, 11.99), control1: p(9.2, 16.63), control2: p(9.19, 15.35))
        path.addCurve(to: p(9.22, 7.37), control1: p(9.19, 8.29), control2: p(9.2, 7.36))
        path.closeSubpath()
        return path
    }
}

/// Plex's chevron, as the letter x of its wordmark draws it (Simple Icons,
/// icons/plex.svg, CC0), centred in whatever square it is given.
private struct PlexChevron: Shape {
    func path(in rect: CGRect) -> Path {
        // The chevron's own box in the wordmark: x 16.752...21.39, y 8.623...15.29.
        let width: CGFloat = 4.638, height: CGFloat = 6.667
        let scale = min(rect.width / width, rect.height / height)
        let origin = CGPoint(x: rect.midX - width * scale / 2, y: rect.midY - height * scale / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (x - 16.752) * scale, y: origin.y + (y - 8.623) * scale)
        }
        var path = Path()
        path.move(to: p(19.142, 15.29))
        path.addLine(to: p(16.752, 15.29))
        path.addLine(to: p(18.999, 11.958))
        path.addLine(to: p(16.752, 8.623))
        path.addLine(to: p(19.142, 8.623))
        path.addLine(to: p(21.39, 11.958))
        path.closeSubpath()
        return path
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

/// A server's mark as a Settings tile: on a dark rounded square, the way an
/// app's icon sits in a list. Plex's mark is a square of its own already.
struct MediaServerLogoTile: View {
    let brand: MediaServerBrand
    var size: CGFloat = 30

    var body: some View {
        Group {
            if case .plex = brand {
                MediaServerLogo(brand: brand)
            } else {
                MediaServerLogo(brand: brand).padding(size * 0.17)
            }
        }
        .frame(width: size, height: size)
        .background(LineupPanelStyle.listLogoTile,
                    in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}
