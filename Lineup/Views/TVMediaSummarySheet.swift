#if os(tvOS)
import SwiftUI
import UIKit

/// A separate focus target below the artwork. Reading a summary never changes
/// the size of a playable card.
struct TVMediaSummaryPreview: View {
    let text: String
    var compact = false
    let action: () -> Void

    var body: some View {
        TVSelectable(scale: 1.015, fillRadius: 14, action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(compact ? .inter(.caption) : .inter(22))
                    .foregroundStyle(LineupStyle.text.opacity(0.76))
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text("Full Summary")
                    Image(systemName: "chevron.right")
                }
                .font(.inter(compact ? 17 : 19, .semibold))
                .foregroundStyle(LineupStyle.highlight)
            }
            .multilineTextAlignment(.leading)
            .padding(compact ? 12 : 22)
            .background(LineupPanelStyle.fill.opacity(0.88),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("Full summary. \(text)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Uses the same charcoal panel, tiled heading and divider as TVChoiceSheet.
/// UITextView supplies tvOS's native remote scrolling for very long summaries.
struct TVMediaSummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var media: MediaLibrary
    private let originalItem: MediaItem
    private var item: MediaItem { media.displayItem(originalItem) }

    init(item: MediaItem) { originalItem = item }

    private var metadata: String {
        [item.episodeCode ?? item.productionYear.map(String.init),
         item.type == "Episode" ? item.formattedAirDate : nil,
         item.formattedRuntime, item.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private var summary: String { item.overview ?? "No summary available." }

    private var textHeight: CGFloat {
        let bounds = TVSummaryText.attributed(summary).boundingRect(
            with: CGSize(width: 1040, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return min(max(ceil(bounds.height) + 16, 100), 460)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    LineupIconTile(symbol: item.type == "Episode" ? "tv" : "film", size: 52)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.name).font(.inter(30, .bold)).lineLimit(2)
                        if !metadata.isEmpty {
                            Text(metadata).font(.inter(20)).foregroundStyle(LineupPanelStyle.quiet)
                        }
                        if let genres = item.genres, !genres.isEmpty {
                            Text(genres.joined(separator: " · "))
                                .font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(30)
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.horizontal, 30)
                TVSummaryText(text: summary)
                    .frame(height: textHeight)
                    .padding(.horizontal, 30).padding(.vertical, 22)
                LibraryMetadataCredit(item: item).padding(.horizontal, 30).padding(.bottom, 12)
                if textHeight == 460 {
                    Text("Scroll to read more")
                        .font(.inter(17)).foregroundStyle(LineupPanelStyle.quiet)
                        .padding(.horizontal, 30).padding(.bottom, 18)
                }
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.horizontal, 30)
                TVSelectable(scale: 1.02, fillRadius: 18, action: { dismiss() }, requestInitialFocus: true) {
                    Text("Done").font(.inter(24, .bold))
                        .frame(maxWidth: .infinity).frame(height: 70)
                }
                .padding(14)
            }
            .foregroundStyle(LineupStyle.text)
            .frame(width: 1100)
            .background(LineupPanelStyle.fill, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
            .focusSection()
        }
        .onExitCommand { dismiss() }
    }
}

private struct TVSummaryText: UIViewRepresentable {
    let text: String

    static func attributed(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        return NSAttributedString(string: text, attributes: [
            .font: UIFont(name: LineupFonts.face(for: .regular), size: 24) ?? .systemFont(ofSize: 24),
            .foregroundColor: UIColor(LineupStyle.text).withAlphaComponent(0.86),
            .paragraphStyle: paragraph
        ])
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        // Text editing is unavailable on tvOS; the native text view remains
        // focusable and scrollable with the remote.
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.showsVerticalScrollIndicator = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard uiView.text != text else { return }
        uiView.attributedText = Self.attributed(text)
        uiView.setContentOffset(.zero, animated: false)
    }
}
#endif
