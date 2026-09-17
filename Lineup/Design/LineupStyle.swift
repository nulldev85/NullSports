import SwiftUI

enum LineupTheme: String, CaseIterable, Identifiable {
    case graphiteIce
    case velvet
    case grandstand
    case pitLane

    static let storageKey = "lineup.appearance.theme"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .graphiteIce: "Graphite Ice"
        case .velvet: "Velvet"
        case .grandstand: "Grandstand"
        case .pitLane: "Pit Lane"
        }
    }

    var detail: String {
        switch self {
        case .graphiteIce: "Graphite & ice blue"
        case .velvet: "Plum & lilac"
        case .grandstand: "Ink & champagne"
        case .pitLane: "Graphite & copper"
        }
    }

    fileprivate var palette: LineupPalette {
        switch self {
        case .graphiteIce:
            LineupPalette(
                accent: rgb(0x38BDF8), ink: rgb(0xF1F5F9), mutedInk: rgb(0x8491A3),
                background: rgb(0x080B10), surface: rgb(0x121720), raised: rgb(0x1A2230),
                sidebar: rgb(0x0D1219), selected: rgb(0x172435), focused: rgb(0x20364D), warning: rgb(0xF2B35D)
            )
        case .velvet:
            LineupPalette(
                accent: rgb(0xC7A7FF), ink: rgb(0xF6F2F8), mutedInk: rgb(0xA9A1AE),
                background: rgb(0x151217), surface: rgb(0x1C181F), raised: rgb(0x27212B),
                sidebar: rgb(0x18141A), selected: rgb(0x241D29), focused: rgb(0x33283A), warning: rgb(0xE49A63)
            )
        case .grandstand:
            LineupPalette(
                accent: rgb(0xE3C77A), ink: rgb(0xF3F1EA), mutedInk: rgb(0x9DA6AA),
                background: rgb(0x081116), surface: rgb(0x0D191F), raised: rgb(0x17262D),
                sidebar: rgb(0x0A151A), selected: rgb(0x132229), focused: rgb(0x20343D), warning: rgb(0xE2A157)
            )
        case .pitLane:
            LineupPalette(
                accent: rgb(0xF08B4A), ink: rgb(0xF2F2EF), mutedInk: rgb(0x9C9D99),
                background: rgb(0x0E0F0F), surface: rgb(0x171818), raised: rgb(0x232525),
                sidebar: rgb(0x121313), selected: rgb(0x202222), focused: rgb(0x303333), warning: rgb(0xE7B65D)
            )
        }
    }
}

fileprivate struct LineupPalette {
    let accent: Color
    let ink: Color
    let mutedInk: Color
    let background: Color
    let surface: Color
    let raised: Color
    let sidebar: Color
    let selected: Color
    let focused: Color
    let warning: Color
}

private func rgb(_ value: UInt32) -> Color {
    Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

enum LineupStyle {
    static var theme: LineupTheme {
        LineupTheme(rawValue: UserDefaults.standard.string(forKey: LineupTheme.storageKey) ?? "") ?? .velvet
    }
    private static var palette: LineupPalette { theme.palette }
    static var lightPurple: Color { palette.accent }
    // White is reserved for selected Live card frames.
    static let liveSelectionBorder = Color.white
    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var raised: Color { palette.raised }
    static var sidebarRow: Color { palette.sidebar }
    static var selected: Color { palette.selected }
    static var focused: Color { palette.focused }
    static var liveSurface: Color { palette.selected }
    static var liveBorder: Color { lightPurple.opacity(0.72) }
    static var line: Color { palette.mutedInk.opacity(0.18) }
    static var text: Color { palette.ink }
    static var secondary: Color { palette.mutedInk }
    static var field: Color { lightPurple }
    static let live = Color(red: 0.98, green: 0.25, blue: 0.30)
    static var focusGlow: Color { lightPurple }
    static var warning: Color { palette.warning }
    static let compactRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12
}

struct LineupThemeSwatch: View {
    let theme: LineupTheme

    var body: some View {
        HStack(spacing: 0) {
            theme.palette.background
            theme.palette.surface
            theme.palette.accent
        }
        .frame(width: 54, height: 24)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }
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
            Text(title).foregroundColor(LineupStyle.text)
                .font(.system(size: 50, weight: .bold, design: .default))
                .tracking(-1.2)
                .foregroundStyle(LineupStyle.text)
            if let detail {
                Text(detail).foregroundColor(LineupStyle.secondary)
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
