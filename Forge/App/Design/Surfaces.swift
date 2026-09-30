import SwiftUI

// Forge's surfaces. The canvas falls off softly from top to bottom under a
// faint accent-tinted light, and cards sit on it like polished tiles: lit
// from above, with a bright rim where the light catches their top edge, a
// hairline outline and a soft shadow. List sections get the same fill and
// top light (iOS clips anything drawn outside a list section, so they rely
// on the canvas for their lift rather than a shadow).

/// The screen background behind lists, forms and cards.
struct CanvasBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            LinearGradient(colors: [Theme.canvasTop, Theme.canvasBottom], startPoint: .top, endPoint: .bottom)
            // Soft light from above, tinted by the accent, with a cooler
            // second source for depth.
            RadialGradient(
                colors: [Color.accentColor.opacity(dark ? 0.16 : 0.14), .clear],
                center: UnitPoint(x: 0.12, y: -0.06),
                startRadius: 0,
                endRadius: 360
            )
            RadialGradient(
                colors: [Theme.mist.opacity(dark ? 0.10 : 0.08), .clear],
                center: UnitPoint(x: 0.96, y: 0.02),
                startRadius: 0,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// How far a card lifts off the canvas.
enum CardElevation {
    /// Free-standing cards: a soft shadow below as well as a contact shadow.
    case raised
    /// Cards inside list rows or tight grids, where a long shadow would be
    /// cut off: only the contact shadow.
    case resting
}

/// A card's surface: drawn behind the card's content.
struct CardSurface: View {
    var cornerRadius: CGFloat = 20
    var elevation: CardElevation = .raised
    /// An optional wash of color over the card (the Train greeting card).
    var tint: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Theme.cardTop, Theme.cardBottom], startPoint: .top, endPoint: .bottom))
            .overlay {
                if let tint {
                    shape.fill(LinearGradient(
                        colors: [tint.opacity(0.17), tint.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                }
            }
            // Gloss: light pooling on the upper part of the card.
            .overlay(
                shape.fill(LinearGradient(
                    colors: [Theme.cardGloss, Theme.cardGloss.opacity(0)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.6)
                ))
            )
            // The rim: bright along the top edge, fading down the sides.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Theme.cardRim, Theme.cardRim.opacity(0.25), Theme.cardRim.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            // A hairline that holds the card's shape against the canvas.
            .overlay(shape.stroke(Theme.cardEdge, lineWidth: 0.5))
            .shadow(color: Theme.cardShadowNear, radius: 1.2, y: 1)
            .shadow(
                color: elevation == .raised ? Theme.cardShadowFar : .clear,
                radius: elevation == .raised ? 14 : 0,
                y: elevation == .raised ? 7 : 0
            )
    }
}

/// Which edges of a list section a row sits on.
struct CardRowEdges: OptionSet {
    let rawValue: Int
    static let top = CardRowEdges(rawValue: 1 << 0)
    static let bottom = CardRowEdges(rawValue: 1 << 1)
    static let all: CardRowEdges = [.top, .bottom]

    /// The edges of the row at `index` in a section of `count` rows.
    static func of(_ index: Int, in count: Int) -> CardRowEdges {
        var edges: CardRowEdges = []
        if index == 0 { edges.insert(.top) }
        if index == count - 1 { edges.insert(.bottom) }
        return edges
    }
}

/// A list row's background, matching the cards: the top row of a section
/// catches the light along its top edge and the bottom row settles into a
/// faint shade, so each section reads as one lit card. The section's
/// rounded corners come from the list, so none of this needs to know them.
struct CardRowBackground: View {
    var edges: CardRowEdges = []
    /// A wash over the row (a completed set's green).
    var tint: Color?

    var body: some View {
        ZStack {
            Theme.cardFill
            if let tint { tint }
            if edges.contains(.top) {
                VStack(spacing: 0) {
                    // Specular line: brightest mid-edge, gone by the corners.
                    LinearGradient(
                        colors: [Theme.cardRim.opacity(0), Theme.cardRim, Theme.cardRim, Theme.cardRim.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 1)
                    LinearGradient(colors: [Theme.cardGloss, Theme.cardGloss.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                    Spacer(minLength: 0)
                }
            }
            if edges.contains(.bottom) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(colors: [Theme.cardShade.opacity(0), Theme.cardShade], startPoint: .top, endPoint: .bottom)
                        .frame(height: 22)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// A card: padded content on a lit, rimmed surface.
    func cardStyle(padding: CGFloat = 16, cornerRadius: CGFloat = 20, elevation: CardElevation = .raised) -> some View {
        self
            .padding(padding)
            .background(CardSurface(cornerRadius: cornerRadius, elevation: elevation))
    }

    /// The card surface without padding (for content that sizes itself).
    func cardSurface(cornerRadius: CGFloat = 20, elevation: CardElevation = .raised, tint: Color? = nil) -> some View {
        background(CardSurface(cornerRadius: cornerRadius, elevation: elevation, tint: tint))
    }

    /// Styles a list row as part of a lit card; pass the edges of the
    /// section it sits on.
    func cardRow(_ edges: CardRowEdges = [], tint: Color? = nil) -> some View {
        listRowBackground(CardRowBackground(edges: edges, tint: tint))
    }

    /// A panel on the full-screen timer's dark backdrop: a faint fill with
    /// a rim of light along its top edge.
    func nightPanel(cornerRadius: CGFloat, fill: Color = .white.opacity(0.06)) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .fill(fill)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                )
        }
    }

    /// The calm canvas behind lists and forms, instead of the system gray.
    func canvasBackground() -> some View {
        scrollContentBackground(.hidden)
            .background { CanvasBackdrop() }
    }
}
