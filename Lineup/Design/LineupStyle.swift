import SwiftUI

enum LineupStyle {
    static let lightPurple = Color(red: 0xD4 / 255.0, green: 0xC7 / 255.0, blue: 0xE1 / 255.0)
    // White is reserved for selected Live card frames.
    static let liveSelectionBorder = Color.white
    static let background = Color(red: 0x22 / 255.0, green: 0x1D / 255.0, blue: 0x27 / 255.0)
    static let surface = Color(red: 0x28 / 255.0, green: 0x21 / 255.0, blue: 0x2D / 255.0)
    static let raised = Color(red: 0x33 / 255.0, green: 0x2B / 255.0, blue: 0x3A / 255.0)
    static let sidebarRow = Color(red: 0x25 / 255.0, green: 0x1F / 255.0, blue: 0x2A / 255.0)
    static let selected = Color(red: 0x2D / 255.0, green: 0x26 / 255.0, blue: 0x33 / 255.0)
    static let focused = Color(red: 0x3D / 255.0, green: 0x34 / 255.0, blue: 0x44 / 255.0)
    static let liveSurface = Color(red: 0x2D / 255.0, green: 0x26 / 255.0, blue: 0x33 / 255.0)
    static let liveBorder = lightPurple.opacity(0.72)
    static let line = lightPurple.opacity(0.11)
    static let text = lightPurple
    static let secondary = lightPurple
    static let field = lightPurple
    static let live = lightPurple
    static let focusGlow = lightPurple
    static let warning = Color(red: 0.78, green: 0.51, blue: 0.35)
}

extension View {
    /// The app's button style, with tvOS's own focus effect switched off.
    ///
    /// `LineupButtonStyle` already draws focus -- a filled background and a
    /// lift. tvOS adds its plate on top of that, sized to the whole button, so
    /// a focused button carried two highlights and the outer one was enormous.
    /// Applying the style is what asks for that plate, so the two travel
    /// together here and a new button cannot pick up one without the other.
    func lineupButtonStyle() -> some View {
        buttonStyle(LineupButtonStyle()).focusEffectDisabled()
    }
}

struct LineupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PurpleButtonLabel(configuration: configuration)
    }

    private struct PurpleButtonLabel: View {
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(LineupStyle.lightPurple)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(focused ? LineupStyle.focused : LineupStyle.raised,
                            in: RoundedRectangle(cornerRadius: 12))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }
    }
}

extension View {
    @ViewBuilder
    func nullGlass(clear: Bool = false, cornerRadius: CGFloat = 18) -> some View {
        self
            .background(LineupStyle.surface.opacity(clear ? 0.72 : 0.94), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(LineupStyle.line, lineWidth: 1))
    }

    func focusLift(_ focused: Bool, scale: CGFloat = 1.035) -> some View {
        self
            .scaleEffect(focused ? scale : 1)
            .offset(y: focused ? -3 : 0)
            .shadow(color: focused ? LineupStyle.focusGlow.opacity(0.20) : .clear, radius: 22, y: 10)
            .zIndex(focused ? 10 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.78), value: focused)
    }
}

struct PageTitle: View {
    let eyebrow: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased()).foregroundColor(LineupStyle.lightPurple)
                .font(.caption.weight(.bold))
                .tracking(1.8)
                .foregroundStyle(LineupStyle.field)
            Text(title).foregroundColor(LineupStyle.lightPurple)
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(LineupStyle.text)
            if let detail {
                Text(detail).foregroundColor(LineupStyle.lightPurple)
                    .font(.title3)
                    .foregroundStyle(LineupStyle.secondary)
            }
        }
    }
}

struct LeagueMark: View {
    let league: SportsLeague

    var body: some View {
        Text(league.shortName).foregroundColor(LineupStyle.lightPurple)
            .font(.system(size: 16, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(LineupStyle.text)
            .frame(width: 72, height: 44)
            .background(LineupStyle.raised)
            .overlay(Rectangle().frame(height: 3).foregroundStyle(league.color), alignment: .bottom)
    }
}
