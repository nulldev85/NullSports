import SwiftUI

enum NullSportsStyle {
    static let background = Color(red: 0.040, green: 0.047, blue: 0.065)
    static let surface = Color(red: 0.075, green: 0.090, blue: 0.125)
    static let raised = Color(red: 0.105, green: 0.125, blue: 0.170)
    static let selected = Color(red: 0.145, green: 0.200, blue: 0.315)
    static let focused = Color(red: 0.205, green: 0.300, blue: 0.500)
    static let line = Color(red: 0.43, green: 0.49, blue: 0.62).opacity(0.30)
    static let text = Color(red: 0.94, green: 0.95, blue: 0.97)
    static let secondary = Color(red: 0.63, green: 0.68, blue: 0.76)
    static let field = Color(red: 0.48, green: 0.67, blue: 0.93)
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
