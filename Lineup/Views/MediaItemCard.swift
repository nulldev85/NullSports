import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// IMDb, TMDB, Rotten Tomatoes, Metacritic and Letterboxd as dark chips,
/// each source named in its own colour the way the sites' own badges are.
struct MediaRatingChips: View {
    let ratings: MediaRatings
    var centered = false

    private typealias Metrics = MediaRatingMetrics

    var body: some View {
        #if os(iOS)
        // Five sources can be wider than a phone: the chips tighten before
        // they take a second line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.gap) { chips(tight: false) }.fixedSize()
            HStack(spacing: Metrics.tightGap) { chips(tight: true) }.fixedSize()
            BadgeFlow(spacing: Metrics.tightGap, centered: centered) { chips(tight: true) }
        }
        #else
        HStack(spacing: Metrics.gap) { chips(tight: false) }
            .fixedSize()
        #endif
    }

    @ViewBuilder
    private func chips(tight: Bool) -> some View {
        if let imdb = ratings.imdb {
            let shown = String(format: "%.1f", imdb)
            chip("Rating-IMDb", spoken: "IMDb", spokenValue: shown, tight: tight) { value(shown, tight: tight) }
        }
        if let tmdb = ratings.tmdb {
            let shown = String(format: "%.1f", tmdb)
            chip("Rating-TMDB", spoken: "TMDB", spokenValue: shown, tight: tight) { value(shown, tight: tight) }
        }
        if let tomatoes = ratings.rottenTomatoes {
            chip("Rating-RT", spoken: "Rotten Tomatoes", spokenValue: "\(tomatoes)%", tight: tight) {
                value("\(tomatoes)%", tight: tight)
            }
        }
        if let metascore = ratings.metacritic {
            chip("Rating-Metacritic", spoken: "Metacritic", spokenValue: "\(metascore)", tight: tight) {
                metascoreBox(metascore, tight: tight)
            }
        }
        if let stars = ratings.letterboxd {
            // Three dots side by side: as wide as IMDb's badge at a little
            // over half the height.
            chip("Rating-Letterboxd", spoken: "Letterboxd", spokenValue: String(format: "%.1f out of 5", stars),
                 logoScale: 0.62, tight: tight) {
                value(String(format: "%.1f", stars), tight: tight)
            }
        }
    }

    private func value(_ text: String, tight: Bool) -> some View {
        Text(text)
            .font(.interDigits(tight ? Metrics.tightValueSize : Metrics.valueSize, .bold))
            .foregroundStyle(Color.white)
    }

    /// The Metascore in the box Metacritic draws it in: green from 61,
    /// yellow from 40, red below.
    private func metascoreBox(_ score: Int, tight: Bool) -> some View {
        let fill = score >= 61 ? Color(red: 0, green: 0.808, blue: 0.478)
            : score >= 40 ? Color(red: 1, green: 0.741, blue: 0.247) : Color(red: 1, green: 0.408, blue: 0.455)
        let size = tight ? Metrics.tightValueSize : Metrics.valueSize
        return Text("\(score)")
            .font(.interDigits(size, .bold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 4)
            .frame(minWidth: size * 1.7, minHeight: size * 1.35)
            .background(fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// Each site by its own mark rather than its name in letters: IMDb's
    /// yellow badge, TMDB's square mark and the Tomatometer's tomato, all
    /// the same height.
    private func chip<Value: View>(_ logo: String, spoken: String, spokenValue: String,
                                   logoScale: CGFloat = 1, tight: Bool,
                                   @ViewBuilder value: () -> Value) -> some View {
        let content = value()
        return HStack(spacing: tight ? Metrics.tightInner : Metrics.inner) {
            Image(logo)
                .resizable()
                .scaledToFit()
                .frame(height: (tight ? Metrics.tightLogo : Metrics.logo) * logoScale)
                .accessibilityHidden(true)
            content
        }
        .padding(.horizontal, tight ? Metrics.tightPadding : Metrics.padding)
        .frame(height: Metrics.height)
        .background(Metrics.fill, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spoken) \(spokenValue)")
    }
}

enum MediaRatingMetrics {
    static let fill = Color(red: 0.15, green: 0.16, blue: 0.19).opacity(0.9)
    #if os(tvOS)
    static let height: CGFloat = 42
    static let padding: CGFloat = 14
    static let gap: CGFloat = 12
    static let inner: CGFloat = 11
    static let logo: CGFloat = 26
    static let valueSize: CGFloat = 22
    static let radius: CGFloat = 10
    // One row always fits a television.
    static let tightPadding = padding
    static let tightGap = gap
    static let tightInner = inner
    static let tightLogo = logo
    static let tightValueSize = valueSize
    #else
    static let height: CGFloat = 30
    static let padding: CGFloat = 9
    static let gap: CGFloat = 8
    static let inner: CGFloat = 7
    static let logo: CGFloat = 18
    static let valueSize: CGFloat = 15
    static let radius: CGFloat = 8
    /// The same chips a little closer, for a row that would not fit.
    static let tightPadding: CGFloat = 6
    static let tightGap: CGFloat = 6
    static let tightInner: CGFloat = 5
    static let tightLogo: CGFloat = 15
    static let tightValueSize: CGFloat = 13
    #endif
}

#if os(tvOS)
/// BetterPosters' rated poster, drawn over the ordinary one, as the phone's
/// `MobileRatedPoster` does: both through the same artwork cache, and the
/// ordinary poster shown while the rated one loads and wherever it fails.
struct TVRatedPoster<Content: View>: View {
    let url: URL?
    let fallback: URL?
    let width: CGFloat
    @ViewBuilder var content: (Image?) -> Content

    var body: some View {
        if let url, url != fallback {
            LineupArtView(url: fallback, width: width) { ordinary in
                LineupArtView(url: url, width: width) { rated in content(rated ?? ordinary) }
            }
        } else {
            LineupArtView(url: fallback, width: width, content: content)
        }
    }
}
#endif

/// An episode's primary image is a 16:9 still and a movie's is a portrait poster.
/// Choosing per item is what left a shelf ragged, so a screen picks one shape
/// from what it is showing and every card on it is cut to that shape.
enum MediaArtShape {
    case poster
    case still

    var ratio: CGFloat { self == .poster ? 2 / 3 : 16 / 9 }

    var isPoster: Bool { self == .poster }

    static func forItems(_ items: [MediaItem]) -> MediaArtShape {
        if items.isEmpty { return .poster }
        return items.contains(where: { $0.type != "Episode" }) ? .poster : .still
    }
}

struct MediaItemCard: View {
    @Environment(MediaLibrary.self) private var media
    #if !os(tvOS)
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .subheadline) private var titleHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .caption2) private var metadataHeight: CGFloat = 16
    #endif
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var artworkFocused
    #endif
    private let originalItem: MediaItem
    private var item: MediaItem { media.displayItem(originalItem) }
    var shape: MediaArtShape = .poster

    init(item: MediaItem, shape: MediaArtShape = .poster) {
        originalItem = item
        self.shape = shape
    }

    var body: some View {
        let playback = playbackPresentation
        return VStack(alignment: .leading, spacing: 10) {
            // A resizable image keeps its own pixel size as its ideal size, so an
            // aspect box built around the art still took the shape of whatever the
            // server sent: shelves stayed ragged, and a 16:9 episode still grew
            // past its cell and painted over the cards beside it. The box is a
            // clear rectangle with no size of its own, sized from the width the
            // grid offers, and the art hangs off it as an overlay where filling
            // and cropping cannot reach the layout.
            artworkFrame(playback: playback)
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .lineupFocusLayer(artworkIsFocused, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                // An episode the server does not have yet: the day it airs.
                .overlay(alignment: .topLeading) {
                    if let label = item.upcomingLabel {
                        Text(label)
                            .font(.inter(upcomingLabelSize, .heavy)).tracking(LineupPanelStyle.headerTracking)
                            .foregroundStyle(LineupStyle.text)
                            .padding(.horizontal, upcomingLabelSize * 0.8).padding(.vertical, upcomingLabelSize * 0.4)
                            .background(LineupPanelStyle.fill.opacity(0.92), in: Capsule())
                            .padding(upcomingLabelSize * 0.8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if playback?.watched == true {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(LineupStyle.background)
                            .frame(width: 25, height: 25)
                            .background(LineupStyle.lightPurple, in: Circle())
                            .padding(9)
                    }
                }
            // Two lines are held whether or not the title needs them, so the line
            // under it lands on the same baseline across a row.
            Text(item.name).font(titleFont).lineLimit(2, reservesSpace: true)
                #if os(tvOS)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                #else
                .frame(height: titleHeight, alignment: .topLeading)
                #endif
            #if !os(tvOS)
            // The television shows a poster and its title and nothing more:
            // "MOVIE · 2026" under every card was clutter a viewer reads past.
            // The phone keeps the line on every card, so a row stays even.
            HStack(spacing: 7) {
                if StreamingService.service(for: item) != nil {
                    Text(item.childCount == 1 ? "1 TITLE" : "\(item.childCount ?? 0) TITLES")
                } else {
                    Text(item.type.uppercased())
                    if let year = item.productionYear { Text("· \(String(year))") }
                    if let count = item.childCount { Text("· \(count)") }
                }
            }
            .font(.inter(.caption2, .medium))
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.58))
            .lineLimit(1)
            .frame(height: metadataHeight, alignment: .topLeading)
            #endif
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .task(id: media.metadataRequestKey(for: originalItem)) {
            await media.resolveMetadata(for: originalItem)
        }
        .task(id: media.betterPostersEnabled ? originalItem.libraryKey : "") {
            await media.resolveBetterPosterIdentity(for: originalItem)
        }
    }

    private var artworkIsFocused: Bool {
        #if os(tvOS)
        artworkFocused
        #else
        false
        #endif
    }

    @ViewBuilder private func artworkFrame(playback: MediaCardPlayback?) -> some View {
        #if os(tvOS)
        TVMediaArtwork(playback: playback) { picture }
            .aspectRatio(shape.ratio, contentMode: .fit)
        #else
        Color.clear.frame(maxWidth: .infinity)
            .aspectRatio(shape.ratio, contentMode: .fit)
            .overlay { picture }
            .overlay(alignment: .bottom) {
                if let playback { MediaArtworkProgress(playback: playback) }
            }
        #endif
    }

    private var picture: some View {
        ZStack {
            if let service = StreamingService.service(for: item) {
                StreamingServicePoster(service: service)
            } else {
                LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                #if os(tvOS)
                // BetterPosters' rated poster over the ordinary one, which
                // stays while it loads and wherever it fails.
                TVRatedPoster(url: shape.isPoster ? media.betterPosterURL(for: item) : nil,
                              fallback: artworkURL, width: artWidth) { loaded in
                    if let image = loaded { image.resizable().scaledToFill() }
                    else { Image(systemName: item.isFolder ? "rectangle.stack.fill" : "film.fill").font(.inter(.largeTitle)) }
                }
                #else
                let art = Self.art(for: item, shape: shape, in: media, scale: displayScale)
                MobileRatedPoster(url: shape.isPoster ? media.betterPosterURL(for: item) : nil,
                                  fallback: art.url, pixels: art.pixels) { loaded in
                    if let image = loaded { image.resizable().scaledToFill() }
                    else { Image(systemName: item.isFolder ? "rectangle.stack.fill" : "film.fill").font(.inter(.largeTitle)) }
                }
                #endif
            }
        }
    }


    /// A show's poster -- or an episode's, standing in for its show --
    /// counts episodes; anything else counts time.
    private var playbackPresentation: MediaCardPlayback? {
        media.cardPlayback(for: item, asShow: item.isSeries || (shape.isPoster && item.type == "Episode"))
    }

    /// The widest this card is ever drawn -- the top of the grid's adaptive
    /// range, which is wider than the fixed width a shelf gives it. One size
    /// per shape means a title scrolled past in a shelf and met again in a
    /// grid is the same cached picture both times.
    private var artWidth: CGFloat { Self.artWidth(shape) }
    private var artworkURL: URL? {
        Self.artworkURL(for: item, shape: shape, in: media)
    }

    /// The card's art, address and size, worked out without a card, so a
    /// shelf can fetch it before the card is drawn and the card finds it
    /// made (`LineupArt.prefetch`).
    #if os(tvOS)
    static func art(for item: MediaItem, shape: MediaArtShape, in media: MediaLibrary) -> (url: URL?, pixels: Int) {
        (artworkURL(for: item, shape: shape, in: media), LineupArt.pixels(for: artWidth(shape)))
    }
    #else
    static func art(for item: MediaItem, shape: MediaArtShape, in media: MediaLibrary,
                    scale: CGFloat = UITraitCollection.current.displayScale) -> (url: URL?, pixels: Int) {
        let size = MobileLibraryArtworkSize(width: artWidth(shape), ratio: shape.ratio, scale: scale)
        let url: URL?
        if shape.isPoster, item.type == "Episode" {
            url = media.seriesPosterURL(for: item, width: size.width)
                ?? media.imageURL(for: item, width: size.width)
        } else {
            url = media.imageURL(for: item, width: size.width)
        }
        return (url, size.longestEdge)
    }
    #endif

    private static func artWidth(_ shape: MediaArtShape) -> CGFloat {
        #if os(tvOS)
        shape == .poster ? 310 : 460
        #else
        shape == .poster ? 210 : 300
        #endif
    }

    private static func artworkURL(for item: MediaItem, shape: MediaArtShape, in media: MediaLibrary) -> URL? {
        let width = Int(artWidth(shape))
        if shape.isPoster, item.type == "Episode" {
            return media.seriesPosterURL(for: item, width: width)
                ?? media.imageURL(for: item, width: width)
        }
        return media.imageURL(for: item, width: width)
    }
    private var cardRadius: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }
    private var upcomingLabelSize: CGFloat {
        #if os(tvOS)
        16
        #else
        10
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        // tvOS's semantic headline size is designed for page copy and made
        // shelf labels compete with the poster itself. A compact lockup size
        // stays readable from the couch, keeps long names to two clean lines,
        // and lets more of the next catalog remain visible.
        .inter(22, .semibold)
        #else
        .inter(.subheadline, .semibold)
        #endif
    }
}

#if os(tvOS)
/// The visible card owns progress, independently of the source image's fill
/// bounds. A portrait filling a still can extend far beyond the thumbnail;
/// attaching progress to that image puts its bar outside the clipped card.
struct TVMediaArtwork<Artwork: View>: View {
    let playback: MediaCardPlayback?
    private let artwork: Artwork

    init(playback: MediaCardPlayback?, @ViewBuilder artwork: () -> Artwork) {
        self.playback = playback
        self.artwork = artwork()
    }

    var body: some View {
        Color.clear.frame(maxWidth: .infinity)
            .overlay { artwork }
            .overlay(alignment: .bottom) {
                if let playback { MediaArtworkProgress(playback: playback) }
            }
    }
}
#endif

/// Where a viewer is in a title, laid across the foot of its artwork: the
/// words, the track under them, and a shade behind both so they read over
/// light art and dark alike.
///
/// It used to sit between the artwork and the title, which pushed that one
/// card's title a line below its neighbours'. On the art it takes no height
/// of the card's own, so every title in a row lines up.
/// Where the viewer is, on the art: a play mark, a bar and a few words over a
/// dark fall at the foot of the picture -- "8 of 16" for a show, the time
/// left for a film -- and, for a show, the episode under way as a thin bar
/// along the card's bottom edge.
struct MediaArtworkProgress: View {
    let playback: MediaCardPlayback

    var body: some View {
        VStack(spacing: playback.episodeFraction == nil ? 0 : rowToEdge) {
            HStack(spacing: gap) {
                Image(systemName: "play.fill")
                    .font(.system(size: glyph, weight: .bold, design: .rounded))
                MediaProgressTrack(fraction: playback.fraction, thickness: track)
                Text(playback.label)
                    .font(.interDigits(labelSize, .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(.horizontal, inset)
            .padding(.bottom, playback.episodeFraction == nil ? inset : 0)
            if let episode = playback.episodeFraction {
                // Flush with the card's foot, rounded by its corners.
                MediaProgressTrack(fraction: episode, thickness: edge, rounded: false, rest: 0.28)
            }
        }
        .padding(.top, inset * 3.2)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.5), location: 0.4),
                .init(color: .black.opacity(0.84), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(playback.spoken)
    }

    #if os(tvOS)
    private var glyph: CGFloat { 17 }
    private var track: CGFloat { 9 }
    private var labelSize: CGFloat { 19 }
    private var gap: CGFloat { 12 }
    private var inset: CGFloat { 14 }
    private var edge: CGFloat { 6 }
    private var rowToEdge: CGFloat { 12 }
    #else
    private var glyph: CGFloat { 10 }
    private var track: CGFloat { 5 }
    private var labelSize: CGFloat { 12 }
    private var gap: CGFloat { 7 }
    private var inset: CGFloat { 9 }
    private var edge: CGFloat { 3 }
    private var rowToEdge: CGFloat { 8 }
    #endif
}

/// The app's progress bar on the art: the accent on a grey track. Along the
/// card's foot it runs flush, squared off and rounded only by the card's own
/// corners.
struct MediaProgressTrack: View {
    let fraction: Double
    let thickness: CGFloat
    var rounded = true
    var rest = 0.3

    var body: some View {
        if rounded {
            LineupProgressBar(value: fraction, height: thickness, track: .white.opacity(rest))
        } else {
            GeometryReader { proxy in
                let filled = proxy.size.width * CGFloat(min(max(fraction, 0), 1))
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(rest))
                    Rectangle().fill(LineupStyle.highlight).frame(width: filled)
                }
            }
            .frame(height: thickness)
        }
    }
}
