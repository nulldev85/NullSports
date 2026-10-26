import SwiftUI

struct LiveQualityProgress: View {
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            LineupIconTile(symbol: "play.tv", size: 32)
            ProgressView()
            Text("Opening channel…").font(.inter(.body, .bold))
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel", action: cancel).lineupButtonStyle()
        }
        .padding(20)
        .foregroundStyle(LineupPresentationStyle.text)
        .lineupPresentationSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .lineupPresentation()
        .padding()
    }
}
