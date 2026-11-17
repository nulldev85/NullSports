import SwiftUI

/// A server software's mark, in its own colours, sized to fit the frame it is
/// given.
struct MediaServerLogo: View {
    let brand: MediaServerBrand

    var body: some View {
        switch brand {
        case .silo:
            Image("SiloServerLogo").resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(brand.name)
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
        .accessibilityLabel("Jellyfin, Emby or Silo")
    }
}

extension MediaServerBrand {
    /// The colours of the brand's own logo: Jellyfin's purple into blue,
    /// Emby's green, Silo's blue, red and orange.
    private var logoRGB: [(red: Double, green: Double, blue: Double)] {
        switch self {
        case .jellyfin: [(0xAA / 255, 0x5C / 255, 0xC3 / 255), (0x00 / 255, 0xA4 / 255, 0xDC / 255)]
        case .emby: [(0x52 / 255, 0xB5 / 255, 0x4B / 255), (0.24, 0.56, 0.22)]
        case .silo: [(0.09, 0.31, 1.0), (0.91, 0.12, 0.26), (1.0, 0.52, 0.08)]
        }
    }

    /// The logo's colours as its Library wears them: the same hues, softened
    /// and drawn down toward the app's dark ground, the way the app's own
    /// accents sit on it, rather than at the full strength of a logo.
    var libraryColors: [Color] { logoRGB.map { Self.toned($0, lift: 0) } }

    /// The logo's colours as a card wears them, the way the Sports cards
    /// wear a team's: the colour itself, a dark one lifted so it reads, laid
    /// faintly over the card rather than filling it.
    var cardTints: [Color] {
        logoRGB.map { colour in
            var (red, green, blue) = colour
            let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
            if luminance < 0.45 {
                let mix = (0.45 - luminance) / max(0.01, 1 - luminance)
                red += (1 - red) * mix; green += (1 - green) * mix; blue += (1 - blue) * mix
            }
            return Color(red: red, green: green, blue: blue)
        }
    }

    /// The Library's one colour, for what is chosen: its logo's first.
    var libraryTint: Color { libraryColors[0] }

    /// The same colour lifted a little, for a chevron or a word on the dark
    /// ground, where the deeper one would sink.
    var libraryAccent: Color { Self.toned(logoRGB[0], lift: 0.32) }

    /// A chosen chip's fill: the logo's colours, toned, corner to corner.
    var libraryGradient: LinearGradient {
        LinearGradient(colors: libraryColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A faint wash of the Library's colour at the top, fading into the
    /// app's own ground.
    func libraryWash(_ strength: Double) -> LinearGradient {
        LinearGradient(colors: [libraryTint.opacity(strength), libraryTint.opacity(strength * 0.3), .clear],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55))
    }

    /// A third of the way to grey, then a quarter of the way to the app's
    /// charcoal; `lift` then takes it that far toward white.
    private static func toned(_ colour: (red: Double, green: Double, blue: Double), lift: Double) -> Color {
        let grey = 0.299 * colour.red + 0.587 * colour.green + 0.114 * colour.blue
        let ground = (red: 0.11, green: 0.11, blue: 0.12)
        func channel(_ value: Double, _ base: Double) -> Double {
            let softened = value + (grey - value) * 0.32
            let deepened = softened * 0.74 + base * 0.26
            return deepened + (1 - deepened) * lift
        }
        return Color(red: channel(colour.red, ground.red), green: channel(colour.green, ground.green),
                     blue: channel(colour.blue, ground.blue))
    }

    var loginTint: Color {
        switch self {
        case .jellyfin: Color(red: 0.67, green: 0.36, blue: 0.76)
        case .emby: Color(red: 0.32, green: 0.71, blue: 0.29)
        case .silo: Color(red: 0.09, green: 0.31, blue: 1.0)
        }
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
/// app's icon sits in a list.
struct MediaServerLogoTile: View {
    let brand: MediaServerBrand
    var size: CGFloat = 30

    var body: some View {
        MediaServerLogo(brand: brand).padding(size * 0.17)
        .frame(width: size, height: size)
        .background(LineupPanelStyle.listLogoTile,
                    in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}
