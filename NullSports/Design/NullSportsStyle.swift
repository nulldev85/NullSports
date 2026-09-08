import SwiftUI

enum NullSportsStyle {
    static let lightPurple = Color(red: 0xBB / 255.0, green: 0x9A / 255.0, blue: 0xDD / 255.0)
    // White is reserved for the Guide playhead and selected Live card frames.
    static let guidePlayhead = Color.white
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

struct NullSportsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PurpleButtonLabel(configuration: configuration)
    }

    private struct PurpleButtonLabel: View {
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(NullSportsStyle.lightPurple)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(focused ? NullSportsStyle.focused : NullSportsStyle.raised,
                            in: RoundedRectangle(cornerRadius: 12))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }
    }
}

extension View {
    @ViewBuilder
    func nullGlass(clear: Bool = false, cornerRadius: CGFloat = 18) -> some View {
        self
            .background(NullSportsStyle.surface.opacity(clear ? 0.72 : 0.94), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(NullSportsStyle.line, lineWidth: 1))
    }

    func focusLift(_ focused: Bool, scale: CGFloat = 1.035) -> some View {
        self
            .scaleEffect(focused ? scale : 1)
            .offset(y: focused ? -3 : 0)
            .shadow(color: focused ? NullSportsStyle.focusGlow.opacity(0.20) : .clear, radius: 22, y: 10)
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
            Text(eyebrow.uppercased()).foregroundColor(NullSportsStyle.lightPurple)
                .font(.caption.weight(.bold))
                .tracking(1.8)
                .foregroundStyle(NullSportsStyle.field)
            Text(title).foregroundColor(NullSportsStyle.lightPurple)
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(NullSportsStyle.text)
            if let detail {
                Text(detail).foregroundColor(NullSportsStyle.lightPurple)
                    .font(.title3)
                    .foregroundStyle(NullSportsStyle.secondary)
            }
        }
    }
}

struct LeagueMark: View {
    let league: SportsLeague

    var body: some View {
        Text(league.shortName).foregroundColor(NullSportsStyle.lightPurple)
            .font(.system(size: 16, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(NullSportsStyle.text)
            .frame(width: 72, height: 44)
            .background(NullSportsStyle.raised)
            .overlay(Rectangle().frame(height: 3).foregroundStyle(league.color), alignment: .bottom)
    }
}
