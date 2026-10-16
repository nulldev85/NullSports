import SwiftUI
import LineupAetherPlayback

struct PlaybackFormatBadge: View {
    let text: String
    var body: some View {
        Text(text)
            #if os(tvOS)
            .font(.inter(13, .semibold))
            #else
            .font(.inter(.caption2, .semibold))
            #endif
            .lineLimit(1).fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Stream format: " + text)
            .accessibilityIdentifier("lineup.playback.format." + text)
            .allowsHitTesting(false)
    }
}

/// Pack whole labels onto as many rows as needed, without truncating them
/// or squeezing buttons into the metadata row.
struct PlaybackBadgeFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                 anchor: .topLeading, proposal: ProposedViewSize(layout.sizes[index]))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> (size: CGSize, points: [CGPoint], sizes: [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let finiteWidth = width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let available = max(1, finiteWidth ?? sizes.reduce(0) { $0 + $1.width + spacing })
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > available {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: finiteWidth ?? usedWidth, height: y + rowHeight), points, sizes)
    }
}
