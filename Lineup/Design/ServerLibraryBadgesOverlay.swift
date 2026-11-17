import SwiftUI

/// What a server says about a title's file, over its poster, as the server's
/// own app shows it: resolution and audio at the top, the release type at
/// the foot. Nothing when the server sends none.
struct ServerLibraryBadgesOverlay: View {
    let badges: ServerLibraryBadges?

    #if os(tvOS)
    private let size: CGFloat = 15
    private let inset: CGFloat = 12
    #else
    private let size: CGFloat = 9
    private let inset: CGFloat = 7
    #endif

    var body: some View {
        if let badges, !badges.isEmpty {
            GeometryReader { card in
                // The card is its poster and the lines under it: the badges
                // sit on the poster, whose height its width gives.
                let poster = card.size.width / MediaArtShape.poster.ratio
                VStack(alignment: .leading, spacing: size * 0.45) {
                    ForEach(badges.top, id: \.self) { badge($0) }
                    Spacer(minLength: 0)
                    if let bottom = badges.bottom { badge(bottom) }
                }
                .padding(inset)
                .frame(width: card.size.width, height: min(poster, card.size.height), alignment: .topLeading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.inter(size, .heavy)).tracking(size * 0.06)
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.65).padding(.vertical, size * 0.32)
            .background(Color.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .lineLimit(1)
    }
}
