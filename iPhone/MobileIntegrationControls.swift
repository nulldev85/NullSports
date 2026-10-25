import SwiftUI

/// Login actions size to their contents, with the same quiet tinted surface
/// as the form. Keep a 44-point touch target without stretching the capsule.
struct MobileIntegrationButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.lineupPresentationTint) private var tint
    @Environment(\.mobileIntegrationPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        let accent = tint ?? LineupStyle.highlight
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.inter(.subheadline, .heavy))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background {
                if let palette {
                    shape.fill(LineupPresentationStyle.row)
                    shape.fill(palette.gradient(selected ? 0.40 : 0.23))
                } else { shape.fill(selected ? accent.opacity(0.20) : (tint?.opacity(0.12) ?? LineupPresentationStyle.row)) }
            }
            .overlay {
                if let palette { shape.strokeBorder(palette.gradient(selected ? 0.7 : 0.4), lineWidth: 0.7) }
                else { shape.strokeBorder(selected ? accent.opacity(0.38) : LineupPresentationStyle.border, lineWidth: 0.7) }
            }
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// All sign-in methods stay in one scrollable row. Marks retain their official
/// colors; the API-key option uses a key because it is a credential, not a server.
struct MobileSeerrSignInChoice: View {
    let method: SeerrSignInMethod
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                mark.frame(width: 22, height: 22).accessibilityHidden(true)
                Text(method.title).foregroundStyle(LineupPresentationStyle.text)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(LineupPresentationStyle.text)
                    .frame(width: 11).opacity(selected ? 1 : 0)
            }
        }
        .buttonStyle(MobileIntegrationButtonStyle(selected: selected))
        .environment(\.mobileIntegrationPalette, MobileIntegrationPalette.seerr(method))
        .accessibilityLabel(method.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("lineup.seerr.signin.\(method.rawValue)")
    }

    @ViewBuilder private var mark: some View {
        switch method {
        case .local: Image("SeerrLogo").renderingMode(.original).resizable().scaledToFit()
        case .plex: MediaServerLogo(brand: .plex)
        case .jellyfin: MediaServerLogo(brand: .jellyfin)
        case .emby: MediaServerLogo(brand: .emby)
        case .apiKey: Image(systemName: "key.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(LineupStyle.highlight)
        }
    }
}
