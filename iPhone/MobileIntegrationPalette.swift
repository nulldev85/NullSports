import SwiftUI

/// Original mark colors, used as restrained washes over the app's dark ground.
struct MobileIntegrationPalette {
    let colors: [Color]
    var accent: Color { colors[0] }
    func gradient(_ opacity: Double) -> LinearGradient {
        LinearGradient(colors: colors.map { $0.opacity(opacity) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static func seerr(_ method: SeerrSignInMethod) -> Self {
        switch method {
        case .local, .apiKey: return .init(colors: [Color(red: 0.65, green: 0.49, blue: 0.98), Color(red: 0.39, green: 0.40, blue: 0.95), Color(red: 0.78, green: 0.66, blue: 1)])
        case .jellyfin: return .server(.jellyfin)
        case .emby: return .server(.emby)
        case .plex: return .server(.plex)
        }
    }
    static func server(_ brand: MediaServerBrand) -> Self {
        switch brand {
        case .jellyfin: return .init(colors: [Color(red: 170/255, green: 92/255, blue: 195/255), Color(red: 0, green: 164/255, blue: 220/255)])
        case .emby: return .init(colors: [Color(red: 82/255, green: 181/255, blue: 75/255), Color(red: 0.32, green: 0.71, blue: 0.29), .white])
        case .plex: return .init(colors: [Color(red: 229/255, green: 160/255, blue: 13/255), Color(red: 31/255, green: 31/255, blue: 31/255)])
        case .silo: return .init(colors: [Color(red: 0.09, green: 0.31, blue: 1), Color(red: 0.91, green: 0.12, blue: 0.26), Color(red: 1, green: 0.52, blue: 0.08)])
        }
    }
}

private struct MobileIntegrationPaletteKey: EnvironmentKey {
    static let defaultValue: MobileIntegrationPalette? = nil
}
extension EnvironmentValues {
    var mobileIntegrationPalette: MobileIntegrationPalette? {
        get { self[MobileIntegrationPaletteKey.self] }
        set { self[MobileIntegrationPaletteKey.self] = newValue }
    }
}

struct MobileBrandPanel: ViewModifier {
    let palette: MobileIntegrationPalette
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content.background {
                shape.fill(LineupPresentationStyle.card)
                shape.fill(palette.gradient(0.16))
            }
            .overlay(shape.strokeBorder(palette.gradient(0.42), lineWidth: 0.8).allowsHitTesting(false))
            .clipShape(shape)
            .environment(\.mobileIntegrationPalette, palette)
            .environment(\.lineupPresentationTint, palette.accent)
            .tint(palette.accent)
    }
}

struct MobileIntegrationFieldSurface: ViewModifier {
    @Environment(\.mobileIntegrationPalette) private var palette
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content.background(LineupPresentationStyle.ground.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(palette?.gradient(0.28) ?? MobileIntegrationPalette(colors: [.white]).gradient(0.06), lineWidth: 0.7).allowsHitTesting(false))
    }
}

struct MobileSeerrTheme: ViewModifier {
    let method: SeerrSignInMethod
    func body(content: Content) -> some View {
        let palette = MobileIntegrationPalette.seerr(method)
        content.environment(\.mobileIntegrationPalette, palette)
            .lineupPresentation(tint: palette.accent)
    }
}
