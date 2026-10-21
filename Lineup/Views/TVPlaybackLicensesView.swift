#if os(tvOS)
import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

struct TVPlaybackLicensesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Playback acknowledgements").font(.inter(36, .bold))
            PlaybackEngineText("AetherEngine 7.40.1, MPVKit (LGPL), and their decoder libraries", size: 21)
                .font(.inter(21)).foregroundStyle(LineupPanelStyle.quiet)
            TVPlaybackLicenseText(text: AetherPlaybackSession.openSourceNotices() + "\n\n" + MPVPlaybackSession.openSourceNotices())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(40)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 100).padding(.vertical, 50)
        .background(LineupStyle.background)
        .focusSection()
    }
}

private struct TVPlaybackLicenseText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.textContainer.lineFragmentPadding = 0
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) {
        guard uiView.text != text else { return }
        uiView.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont(name: LineupFonts.face(for: .regular), size: 22) ?? .systemFont(ofSize: 22),
            .foregroundColor: UIColor(LineupStyle.text)
        ])
        uiView.setContentOffset(.zero, animated: false)
    }
}
#endif
