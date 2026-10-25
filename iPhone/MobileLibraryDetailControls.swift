import SwiftUI

/// Detail actions share the Guide's subdued panel colors. Selection uses a
/// restrained accent wash; an idle toggle never becomes a bright gray tile.
struct MobileLibraryDetailButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .font(.inter(17, .heavy))
            .foregroundStyle(selected ? LineupStyle.highlight : LineupPresentationStyle.text)
            .frame(minHeight: 50)
            .background(selected ? LineupStyle.highlight.opacity(0.14) : LineupPresentationStyle.row, in: shape)
            .overlay(shape.strokeBorder(selected ? LineupStyle.highlight.opacity(0.28) : LineupPresentationStyle.border, lineWidth: 0.7))
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
