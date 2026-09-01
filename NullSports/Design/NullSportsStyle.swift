import SwiftUI

enum NullSportsStyle {
    static let background = Color(red: 0.025, green: 0.026, blue: 0.027)
    static let surface = Color(red: 0.075, green: 0.077, blue: 0.080)
    static let raised = Color(red: 0.105, green: 0.108, blue: 0.112)
    static let sidebarRow = Color(red: 0.090, green: 0.092, blue: 0.096)
    static let selected = Color(red: 0.185, green: 0.188, blue: 0.195)
    static let focused = Color(red: 0.315, green: 0.318, blue: 0.325)
    static let liveSurface = Color(red: 0.125, green: 0.127, blue: 0.132)
    static let liveBorder = Color.white.opacity(0.72)
    static let line = Color.white.opacity(0.16)
    static let text = Color(red: 0.95, green: 0.95, blue: 0.94)
    static let secondary = Color(red: 0.64, green: 0.64, blue: 0.62)
    static let field = Color(red: 0.88, green: 0.88, blue: 0.86)
    static let warning = Color(red: 0.78, green: 0.51, blue: 0.35)
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
