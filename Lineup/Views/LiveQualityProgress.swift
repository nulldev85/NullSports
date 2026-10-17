import SwiftUI

struct LiveQualityProgress: View {
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text("Checking stream quality…").font(.inter(15, .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel", action: cancel).lineupButtonStyle()
        }
        .padding(20)
        .foregroundStyle(LineupStyle.text)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }
}
