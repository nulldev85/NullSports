import SwiftUI
import UIKit
import LineupAetherPlayback

struct PlaybackFormatBadge: View {
    let text: String
    /// Full screen on the television, read from across the room.
    var large = false
    var body: some View {
        Text(text)
            #if os(tvOS)
            .font(.inter(large ? 21 : 13, .semibold))
            #else
            .font(.inter(.caption2, .semibold))
            #endif
            .lineLimit(1).fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 12 : 8).padding(.vertical, large ? 7 : 5)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: large ? 9 : 6))
            .accessibilityLabel("Stream format: " + text)
            .accessibilityIdentifier("lineup.playback.format." + text)
            .allowsHitTesting(false)
    }
}

/// The playback engines' own logos, in front of their names wherever the
/// app names them: on the picture, in Settings, and in its own sentences. A
/// logo stands a little taller than the letters beside it, so it reads.
enum PlaybackEngineMark {
    /// Each engine's name as the app writes it, and its logo in the asset
    /// catalog. Apple's player has no logo the app may show.
    static let logos: [(name: String, asset: String)] = [("AetherEngine", "Engine-aether"), ("VLC", "Engine-vlc")]

    /// `string` with each engine's name led by its logo, for text of
    /// `pointSize`. Read aloud, it is the words alone.
    static func text(_ string: String, pointSize: CGFloat) -> Text {
        var text = Text(verbatim: "")
        var rest = string[...]
        while let match = nextName(in: rest) {
            let (range, asset) = match
            text = text + Text(verbatim: String(rest[..<range.lowerBound]))
            if let logo = logo(asset, size: (pointSize * 1.2).rounded()) {
                // Centred on the capitals rather than sat on the baseline, and
                // never wrapped away from the name.
                text = text + Text(Image(uiImage: logo)).baselineOffset(-pointSize * 0.25) + Text(verbatim: "\u{202F}")
            }
            text = text + Text(verbatim: String(rest[range]))
            rest = rest[range.upperBound...]
        }
        return (text + Text(verbatim: String(rest))).accessibilityLabel(Text(verbatim: string))
    }

    /// The first engine name in `string` that stands as a word of its own.
    private static func nextName(in string: Substring) -> (Range<Substring.Index>, String)? {
        logos.compactMap { entry -> (Range<Substring.Index>, String)? in
            var from = string.startIndex
            while let range = string.range(of: entry.name, range: from..<string.endIndex) {
                let before = range.lowerBound > string.startIndex ? string[string.index(before: range.lowerBound)] : " "
                let after = range.upperBound < string.endIndex ? string[range.upperBound] : " "
                if !before.isLetter && !after.isLetter { return (range, entry.asset) }
                from = range.upperBound
            }
            return nil
        }
        .min { $0.0.lowerBound < $1.0.lowerBound }
    }

    private static let drawn = NSCache<NSString, UIImage>()

    /// Text shows an image at its own size, so each logo is drawn once at
    /// the size its text needs.
    private static func logo(_ asset: String, size: CGFloat) -> UIImage? {
        let key = "\(asset)@\(size)" as NSString
        if let logo = drawn.object(forKey: key) { return logo }
        guard let source = UIImage(named: asset) else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let logo = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }.withRenderingMode(.alwaysOriginal)
        drawn.setObject(logo, forKey: key)
        return logo
    }
}

/// Words that name a playback engine, each name led by its logo. Give it
/// the point size of the font it is set in, or the text style that font
/// follows, so the logo keeps pace with the reader's text size.
struct PlaybackEngineText: View {
    let string: String
    private let points: CGFloat?
    @ScaledMetric private var scaled: CGFloat

    /// For a fixed font, such as `.inter(21)`.
    init(_ string: String, size: CGFloat) {
        self.string = string
        points = size
        _scaled = ScaledMetric(wrappedValue: size)
    }

    /// For a font of a text style, such as `.inter(.caption)`.
    init(_ string: String, style: Font.TextStyle) {
        self.string = string
        points = nil
        _scaled = ScaledMetric(wrappedValue: Self.standardSize(of: style), relativeTo: style)
    }

    var body: some View { PlaybackEngineMark.text(string, pointSize: points ?? scaled) }

    /// Each style's point size at the standard text size.
    private static func standardSize(of style: Font.TextStyle) -> CGFloat {
        switch style {
        case .caption2: 11
        case .caption: 12
        case .footnote: 13
        case .subheadline: 15
        case .callout: 16
        default: 17
        }
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
