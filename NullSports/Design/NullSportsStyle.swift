import SwiftUI

enum NullSportsStyle {
    static let background = Color(red: 0.012, green: 0.014, blue: 0.018)
    static let surface = Color(red: 0.050, green: 0.054, blue: 0.062)
    static let raised = Color(red: 0.078, green: 0.083, blue: 0.094)
    static let sidebarRow = Color(red: 0.048, green: 0.051, blue: 0.057)
    static let selected = Color(red: 0.145, green: 0.151, blue: 0.162)
    static let focused = Color(red: 0.225, green: 0.232, blue: 0.244)
    static let liveSurface = Color(red: 0.105, green: 0.108, blue: 0.116)
    static let liveBorder = Color.white.opacity(0.72)
    static let line = Color.white.opacity(0.11)
    static let text = Color(red: 0.94, green: 0.94, blue: 0.92)
    static let secondary = Color(red: 0.62, green: 0.63, blue: 0.64)
    static let field = Color(red: 0.84, green: 0.94, blue: 0.96)
    static let live = Color(red: 0.93, green: 0.22, blue: 0.20)
    static let focusGlow = Color(red: 0.68, green: 0.92, blue: 0.97)
    static let warning = Color(red: 0.78, green: 0.51, blue: 0.35)
}

extension View {
    @ViewBuilder
    func nullGlass(clear: Bool = false, cornerRadius: CGFloat = 18) -> some View {
        if #available(tvOS 26.0, *) {
            if clear {
                self.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
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
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.8)
                .foregroundStyle(NullSportsStyle.field)
            Text(title)
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(NullSportsStyle.text)
            if let detail {
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(NullSportsStyle.secondary)
            }
        }
    }
}

struct LeagueMark: View {
    let league: SportsLeague

    var body: some View {
        Text(league.shortName)
            .font(.system(size: 16, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(NullSportsStyle.text)
            .frame(width: 72, height: 44)
            .background(NullSportsStyle.raised)
            .overlay(Rectangle().frame(height: 3).foregroundStyle(league.color), alignment: .bottom)
    }
}
