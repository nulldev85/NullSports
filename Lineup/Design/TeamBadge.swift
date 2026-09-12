import SwiftUI

/// A team's badge, lit by its own silhouette.
///
/// The badge used to sit on a pale disc. Almost no team mark is round — they
/// are shields, wordmarks, animals, letters — so most of that disc was empty
/// light around the artwork, and a ring of blank white read as a sticker
/// pasted onto the card rather than part of it. It did nothing for the badge
/// it was supposedly helping.
///
/// The light is the badge's own shape now. The artwork masks a pale fill and a
/// blur spreads that fill a little past its edges, so what is lit is the mark
/// and a soft rim around it and nothing else. A dark navy shield still reads
/// on a near-black row, which is the only thing the disc was ever for.
///
/// The blur scales with the badge, because a rim sized for a 58-point crest
/// swallows a 28-point one.
struct TeamBadge: View {
    let url: String
    let fallback: String
    /// The badge's drawn size. The rim is derived from it.
    var size: CGFloat

    private var inset: CGFloat { max(2, size * 0.09) }
    private var rim: CGFloat { max(2, size * 0.1) }

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let image = phase.image {
                let art = image.resizable().scaledToFit().padding(inset)
                art.background { halo(art) }
            } else {
                Text(fallback)
                    .font(.system(size: max(7, size * 0.3), weight: .black))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.7))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .transaction { $0.animation = nil }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Two passes of the same blurred silhouette. One alone is too faint to
    /// carry a dark badge, and blurring further only spreads the rim wider
    /// rather than making it brighter.
    private func halo(_ art: some View) -> some View {
        ZStack {
            LineupStyle.logoPlate.mask { art.blur(radius: rim) }
            LineupStyle.logoPlate.mask { art.blur(radius: rim) }
        }
        .opacity(0.9)
    }
}
