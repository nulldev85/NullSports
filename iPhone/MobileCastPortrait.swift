import SwiftUI

/// Try the provider's real portrait first, then its matched TMDB portrait.
/// A missing picture uses initials; it never creates a fake actor image.
struct MobileCastPortrait: View {
    let member: LibraryCastMember
    @Environment(\.displayScale) private var scale
    @StateObject private var artwork = MobileLibraryArtwork()

    var body: some View {
        let pixels = MobileLibraryArtworkSize(width: 96, ratio: 0.75, scale: scale).longestEdge
        let urls = [member.imageURL, member.fallbackImageURL].compactMap { $0 }
        let requests = urls.enumerated().filter { index, url in !urls.prefix(index).contains(url) }
            .map { MobileLibraryArtworkRequest(url: $0.element, pixels: pixels) }
        let image = requests.compactMap { artwork.image(for: $0) ?? LineupArt.ready($0.url, pixels: pixels) }.first
        ZStack {
            LineupPresentationStyle.row
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                Text(member.name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined())
                    .font(.inter(28, .heavy)).foregroundStyle(LineupPresentationStyle.secondary)
            }
        }
        .task(id: requests) {
            for request in requests {
                guard !Task.isCancelled else { return }
                await artwork.load(request)
                guard !Task.isCancelled else { return }
                if artwork.image(for: request) != nil { return }
            }
        }
        .accessibilityHidden(true)
    }
}
