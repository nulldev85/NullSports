import SwiftUI

enum NullSportsStyle {
    static let background = Color(red: 0.035, green: 0.038, blue: 0.036)
    static let surface = Color(red: 0.075, green: 0.080, blue: 0.076)
    static let raised = Color(red: 0.105, green: 0.110, blue: 0.105)
    static let line = Color.white.opacity(0.11)
    static let text = Color(red: 0.92, green: 0.91, blue: 0.86)
    static let secondary = Color(red: 0.61, green: 0.62, blue: 0.58)
    static let field = Color(red: 0.38, green: 0.57, blue: 0.40)
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
