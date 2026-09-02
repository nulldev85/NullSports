import SwiftUI

enum NullSportsStyle {
    static let background = Color(red: 0.018, green: 0.019, blue: 0.022)
    static let surface = Color(red: 0.058, green: 0.061, blue: 0.067)
    static let raised = Color(red: 0.085, green: 0.089, blue: 0.097)
    static let sidebarRow = Color(red: 0.048, green: 0.051, blue: 0.057)
    static let selected = Color(red: 0.145, green: 0.151, blue: 0.162)
    static let focused = Color(red: 0.225, green: 0.232, blue: 0.244)
    static let liveSurface = Color(red: 0.105, green: 0.108, blue: 0.116)
    static let liveBorder = Color.white.opacity(0.72)
    static let line = Color.white.opacity(0.11)
    static let text = Color(red: 0.94, green: 0.94, blue: 0.92)
    static let secondary = Color(red: 0.62, green: 0.63, blue: 0.64)
    static let field = Color(red: 0.86, green: 0.84, blue: 0.78)
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
