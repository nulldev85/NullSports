import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// The page a series or a film opens to: its art, what it is, and what to play
/// -- for a series, the episode the viewer is up to, with every episode of that
/// season under it; for a film, the film.
///
/// A film used to go from its poster straight to a list of streams, which
/// skipped the part where somebody decides whether to watch it: no
/// description, no year, no running time, no rating. It gets this page too now,
/// minus the parts a film has no answer for.
struct MediaDetailScreen: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let item: MediaItem

    @State private var detail: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var selectedSeason: MediaItem?
    @State private var episodes: [MediaItem] = []
    @State private var nextUp: MediaItem?
    @State private var related: [MediaItem] = []
    @State private var pageReady = false
    #if os(tvOS)
    @State private var preparedHero: UIImage?
    @State private var summaryItem: MediaItem?
    #endif
    @State private var favorite = false
    private var watched: Bool { media.isWatched(subject) }
    @State private var expandedOverview = false
    @State private var loading = true
    @State private var error: String?
    @State private var chosen: MediaItem?
    /// Set by Start Over, so the stream that opens ignores the saved place.
    @State private var startingOver = false
    // The native phone row and TV cards hand navigation to the screen so a
    // recycled/offscreen card never owns the destination's lifetime.
    @State private var pushed: MediaItem?
    #if os(tvOS)
    @FocusState private var backFocused: Bool
    @Environment(\.tvTabBar) private var tabBar
    @State private var tabBarPageID = UUID()
    #endif
    @State private var choosingSeason = false
    #if !os(tvOS)
    /// The seasons, dropped from the Seasons button under the episodes'
    /// header.
    @State private var seasonMenuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// IMDb, TMDB and Rotten Tomatoes, once found. The television draws its
    /// page through the hero's own view, which finds them itself.
    @State private var pageRatings: MediaRatings?
    @State private var castCredits: [LibraryCastMember] = []
    @State private var openingSimilar: String?
    @State private var similarTask: Task<Void, Never>?
    @State private var similarLookupID = UUID()
    @State private var similarRequest: SeerrTitleRoute?
    @State private var similarUnavailable = false
    @State private var similarTitle = ""
    @State private var addingServer = false
    #endif

    private var subject: MediaItem { media.displayItem(detail ?? item) }
    /// A title from the Library's charts that no source has yet.
    private var isCatalogOnly: Bool { media.isCatalogOnly(item) }

    var body: some View {
        Group {
            #if os(tvOS)
            if pageReady {
                detailContent
            } else {
                ProgressView("Loading \(item.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mediaFocusAnchor()
            }
            #else
            detailContent
            #endif
        }
        .background(detailGround.ignoresSafeArea())
        .foregroundStyle(detailText)
        #if !os(tvOS)
        .overlayPreferenceValue(MediaSeasonMenuAnchor.self) { anchor in
            GeometryReader { proxy in
                if seasonMenuOpen, let anchor {
                    seasonDropdown(from: proxy[anchor], in: proxy.size)
                }
            }
            .allowsHitTesting(seasonMenuOpen)
        }
        #endif
        .modifier(FullBleedHeader())
        .task(id: item.libraryKey) { await load() }
        .task(id: "title-logo|" + media.metadataRequestKey(for: detail ?? item)) {
            // Begin even while TV prepares seasons/backdrop/focus. The title
            // view can use the same decoded logo on its very first frame.
            await media.warmTitleLogos(for: detail ?? item)
        }
        .task(id: media.metadataRequestKey(for: detail ?? item)) {
            await media.resolveMetadata(for: detail ?? item)
        }
        #if !os(tvOS)
        .task(id: item.libraryKey) { pageRatings = await media.ratings(for: item) }
        .task(id: castRequestKey) {
            castCredits = []
            let requested = subject
            let credits = await media.castCredits(for: requested)
            guard !Task.isCancelled else { return }
            castCredits = credits
        }
        .mobileExpandNavigationOnAppear()
        .task(id: "similar|" + castRequestKey) {
            related = []
            let titles = await media.similarCatalogTitles(for: subject)
            guard !Task.isCancelled else { return }
            related = titles
        }
        .onDisappear {
            similarLookupID = UUID(); similarTask?.cancel(); openingSimilar = nil
        }
        .overlay {
            if openingSimilar != nil {
                ProgressView("Finding your sources…").font(.inter(.callout, .semibold))
                    .padding(20).lineupPresentationSurface(RoundedRectangle(cornerRadius: 18))
                    .allowsHitTesting(false)
            }
        }
        .lineupMessage("Not found in your sources", symbol: "magnifyingglass", isPresented: $similarUnavailable,
            message: "\(similarTitle) was suggested by TMDB, but wasn't found on your connected servers or IPTV VOD.")
        .lineupSheet(item: $similarRequest) { route in
            NavigationStack { SeerrTitleView(id: route.id, kind: route.kind, initialTitle: route.title).environment(media) }
        }
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .lineupSheet(isPresented: $addingServer) {
            MediaServerSetupView().environment(media).preferredColorScheme(.dark)
        }
        .toolbar {
            if ["Movie", "Series"].contains(subject.type), !isCatalogOnly {
                LineupToolbarItem(placement: .primaryAction) {
                    Button("Collections", systemImage: "folder.badge.plus") { media.collectionSelectionItem = subject }
                        .buttonStyle(LineupBarButtonStyle())
                }
            }
        }
        #endif
        #if os(tvOS)
        // Full-screen artwork: the tab bar goes while the page is up.
        .onAppear { tabBar?.pageAppeared(tabBarPageID) }
        .onDisappear { tabBar?.pageDisappeared(tabBarPageID) }
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .onExitCommand { dismiss() }
        .lineupFullScreenCover(item: $chosen, onDismiss: refreshAfterPlayback) { episode in
            MediaSourcePicker(item: episode, startsOver: startingOver)
        }
        .lineupFullScreenCover(item: $summaryItem) { item in
            TVMediaSummarySheet(item: item).presentationBackground(.clear)
        }
        #else
        .lineupSheet(item: $chosen) { episode in MediaSourcePicker(item: episode) }
        #endif
    }

    private var detailContent: some View {
        #if os(tvOS)
        tvDetailContent
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                VStack(alignment: .leading, spacing: 16) {
                    GeometryReader { titleArea in
                        MobileFanartTitle(item: subject, width: titleArea.size.width, height: 88, alignment: .center) {
                            Text(subject.name).font(titleFont).lineLimit(2).minimumScaleFactor(0.8)
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        }
                    }.frame(height: 88)
                    if let ratings = pageRatings ?? media.knownRatings(for: subject), !ratings.isEmpty {
                        MediaRatingChips(ratings: ratings, centered: true).frame(maxWidth: .infinity, alignment: .center)
                    }
                    metaLine.frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
                    if isCatalogOnly { catalogActions } else { actions }
                    overview
                    LibraryMetadataCredit(item: subject).frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, horizontalPadding)
                // Up into the fade. The art running down the screen and the
                // title sitting on the last of it is one picture; the title
                // waiting below a finished band of artwork is two.
                .padding(.top, contentRise)
                if !isCatalogOnly { episodesSection }
                trailersSection
                castSection
                relatedSection
            }
            .padding(.bottom, 44)
        }
        .defaultScrollAnchor(.top)
        .id(item.libraryKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    #if os(tvOS)
    private func refreshAfterPlayback() {
        media.flushLocalPlayback()
        if subject.isSeries {
            Task { nextUp = await media.resumeEpisode(in: subject) }
        }
    }

    /// Selection keeps the same backdrop and information hierarchy as Library
    /// focus, then adds actions and playable rows without dropping into a
    /// separate card-shaped page.
    private var tvDetailContent: some View {
        ZStack(alignment: .top) {
            TVMediaCinematicBackdrop(item: subject)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Room for the ratings above the year and genres.
                    TVMediaLibraryPreview(item: subject)
                        .frame(height: 460)
                        .allowsHitTesting(false)
                    tvActions.padding(.horizontal, horizontalPadding)
                    if let overview = subject.overview, !overview.isEmpty {
                        TVMediaSummaryPreview(text: overview) { summaryItem = subject }
                            .tvHoldMenu(subject.name, symbol: "film") { media.tvCardChoices(for: subject) }
                            .padding(.horizontal, horizontalPadding)
                            .lineupFocusRegion()
                    }
                    episodesSection
                    trailersSection
                    relatedSection
                    LibraryMetadataCredit(item: subject).padding(.horizontal, horizontalPadding)
                }
                .padding(.bottom, 60)
            }
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private var tvActions: some View {
        HStack(spacing: 16) {
            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                         action: { startingOver = false; chosen = playTarget },
                         requestInitialFocus: true) {
                HStack(spacing: 12) {
                    LineupIconTile(symbol: "play.fill", size: 32)
                    Text(playTarget.flatMap { media.resumePosition(for: $0) } == nil ? "Play" : "Resume")
                    if let code = playTarget?.episodeCode {
                        Text(code).opacity(0.62)
                    }
                }
                .font(.inter(18, .semibold))
                .padding(.horizontal, 26).frame(height: 54)
                .modifier(TVMediaActionSurface())
            }
            .disabled(playTarget == nil)
            .opacity(playTarget == nil ? 0.45 : 1)

            // Resume picks up where the viewer left off; this is the way back
            // to the opening scene, which otherwise meant scrubbing for it.
            if playTarget.flatMap({ media.resumePosition(for: $0) }) != nil {
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                             action: { startingOver = true; chosen = playTarget }) {
                    tvSecondaryAction("Start Over", symbol: "backward.end.fill")
                }
            }

            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                favorite.toggle()
                media.setLocalFavorite(favorite, for: subject)
                Task { await media.setFavorite(favorite, for: subject) }
            }) {
                tvSecondaryAction(favorite ? "In Favorites" : "Add to Favorites",
                                  symbol: favorite ? "heart.fill" : "heart")
            }

            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                let value = !media.isWatched(subject)
                Task { await media.setEpisodePlayedAndAdvance(value, for: subject) }
            }) {
                tvSecondaryAction(watched ? "Watched" : "Mark Watched",
                                  symbol: watched ? "eye.fill" : "eye")
            }
        }
        .lineupFocusRegion()
    }

    private func tvSecondaryAction(_ title: String, symbol: String) -> some View {
        LineupTileLabel(title: title, symbol: symbol, tileSize: 32)
            .font(.inter(17, .semibold))
            .padding(.leading, 10).padding(.trailing, 20).frame(height: 52)
            .modifier(TVMediaActionSurface())
    }
    #endif

    // MARK: - Header

    private var hero: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(heroRatio, contentMode: .fit)
            // Top, not centre. A backdrop is 16:9 and this box is wider than
            // that, so filling it crops the difference -- and centred, half of
            // that crop came off the top, which is where the faces are. Anchored
            // here the whole crop falls at the foot of the art, under the fade
            // that is already taking it into the page.
            .overlay {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    #if os(tvOS)
                    if let preparedHero {
                        Image(uiImage: preparedHero).resizable().scaledToFill()
                    }
                    #else
                    MobileLibraryArtView(url: heroURL, pixels: LineupArt.pixels(for: heroWidth)) { loaded in
                        if let image = loaded { image.resizable().scaledToFill() }
                        // The gradient behind is the placeholder, so there is
                        // nothing to draw here -- but something has to be
                        // returned. A closure that can produce no view at all
                        // is what left this blank once already.
                        else { Color.clear }
                    }
                    #endif
                }
            }
            #if os(tvOS)
            .clipped()
            #else
            .mobileLibraryArtworkZoom()
            #endif
            // The art has to end somewhere, and a hard edge across the screen
            // reads as a seam. It fades into the page instead -- over a long
            // way, and through a middle stop, because a two-stop fade over a
            // short distance is a visible band rather than a disappearance.
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: detailGround.opacity(0.62), location: 0.46),
                    .init(color: detailGround, location: 0.9)
                ], startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
            }
            #if os(tvOS)
            // Focus needs a home at the top of the scroll view. Otherwise
            // tvOS chooses Play below the hero and scrolls the whole page on
            // entry, dragging the navigation/tab chrome off the screen.
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .frame(width: 56, height: 56)
                        .background(LineupStyle.background.opacity(0.72), in: Circle())
                }
                .lineupFlatButton()
                .focused($backFocused)
                .padding(.leading, horizontalPadding).padding(.top, 24)
                .onAppear { backFocused = true }
            }
            #endif
    }

    @ViewBuilder
    private var metaLine: some View {
        if !metaParts.isEmpty {
            Text(metaParts.joined(separator: "  \u{00B7}  "))
                .font(.inter(.subheadline, .medium))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
        }
    }

    private var metaParts: [String] {
        [subject.productionYear.map(String.init),
         // Worth saying on a film, where a server reports one; a series has no
         // single running time and leaves this out.
         subject.formattedRuntime,
         subject.genres?.prefix(2).joined(separator: ", "),
         subject.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    // MARK: - Actions

    /// What the play button starts: for a film, the film. For a series, the
    /// server's own next-up answer, else the first unwatched episode on
    /// screen, else the season from the top.
    private var playTarget: MediaItem? {
        guard subject.isSeries else { return subject }
        return media.seriesPlayTarget(in: subject, fallbackEpisodes: episodes, serverNext: nextUp)
    }

    private var actions: some View {
        VStack(alignment: detailActionAlignment, spacing: 10) {
            HStack(spacing: 8) {
                Button { chosen = playTarget } label: {
                    playLabel
                        #if os(tvOS)
                        .modifier(MediaChromeFocus())
                        #endif
                }
                #if os(tvOS)
                .lineupFlatButton()
                #else
                .buttonStyle(MobileLibraryDetailButtonStyle())
                #endif
                .disabled(playTarget == nil)
                #if os(tvOS)
                .opacity(playTarget == nil ? 0.45 : 1)
                #endif

                // Keep the Library useful even when a server cannot write user
                // state, while still mirroring the choice back when it can.
                Group {
                    iconButton("heart", on: favorite) {
                        favorite.toggle()
                        media.setLocalFavorite(favorite, for: subject)
                        Task { await media.setFavorite(favorite, for: subject) }
                    }
                    iconButton("eye", on: watched) {
                        let value = !media.isWatched(subject)
                        Task { await media.setEpisodePlayedAndAdvance(value, for: subject) }
                    }
                }
                // Nothing to shuffle through on a film.
                if subject.isSeries {
                    iconButton("shuffle", on: true) { chosen = episodes.randomElement() ?? playTarget }
                        .disabled(episodes.isEmpty)
                }
            }
            if media.seerr.isConnected {
                NavigationLink { SeerrLibraryRequestView(item: subject).environment(media) } label: {
                    #if os(tvOS)
                    Label("Seerr", systemImage: "tray.and.arrow.down")
                    #else
                    HStack(spacing: 8) {
                        Image("SeerrLogo").renderingMode(.original).resizable().scaledToFit()
                            .frame(width: 22, height: 22).accessibilityHidden(true)
                        Text("Seerr")
                    }.padding(.horizontal, 14)
                    #endif
                }
                #if os(tvOS)
                .lineupButtonStyle()
                #else
                .buttonStyle(MobileLibraryDetailButtonStyle())
                #endif
            }
        }
        #if !os(tvOS)
        .frame(maxWidth: .infinity, alignment: .center)
        #endif
        .lineupFocusRegion()
    }

    #if !os(tvOS)
    /// A chart title's page: Play stays in its place, greyed, with what it
    /// takes to play it. With a source connected, the title is looked for there.
    private var catalogActions: some View {
        VStack(spacing: 12) {
            Button {} label: { playLabel }
                .buttonStyle(MobileLibraryDetailButtonStyle())
                .disabled(true)
            if media.canPlayAnything {
                Button { openSimilar(subject) } label: {
                    Label("Find in My Sources", systemImage: "magnifyingglass").padding(.horizontal, 14)
                }
                .buttonStyle(MobileLibraryDetailButtonStyle())
                .disabled(openingSimilar != nil)
            } else {
                Text("Set up a media server to play this.")
                    .font(.inter(.subheadline)).foregroundStyle(LineupPresentationStyle.secondary)
                    .multilineTextAlignment(.center)
                Button("Add Media Server") { addingServer = true }.lineupProminentButton()
            }
            if media.seerr.isConnected {
                NavigationLink { SeerrLibraryRequestView(item: subject).environment(media) } label: {
                    HStack(spacing: 8) {
                        Image("SeerrLogo").renderingMode(.original).resizable().scaledToFit()
                            .frame(width: 22, height: 22).accessibilityHidden(true)
                        Text("Seerr")
                    }.padding(.horizontal, 14)
                }
                .buttonStyle(MobileLibraryDetailButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
    #endif

    private var detailActionAlignment: HorizontalAlignment {
        #if os(tvOS)
        .leading
        #else
        .center
        #endif
    }

    /// iPhone uses a compact transport glyph with a spoken Play/Resume label;
    /// television retains its existing text and episode-code label.
    @ViewBuilder
    private var playLabel: some View {
        #if !os(tvOS)
        Image(systemName: "play.fill")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(LineupStyle.highlight)
            .frame(width: buttonHeight, height: buttonHeight)
            .accessibilityLabel(playTarget.flatMap { media.resumePosition(for: $0) } == nil ? "Play" : "Resume")
            .accessibilityValue(playTarget?.episodeCode ?? subject.name)
        #else
        let text = HStack(spacing: 10) {
            LineupIconTile(symbol: "play.fill", size: 26)
            Text(playTarget.flatMap { media.resumePosition(for: $0) } == nil ? "Play" : "Resume")
                .font(.inter(17, .heavy))
            if let code = playTarget?.episodeCode {
                // Quieter than the word beside it, on the same dark surface
                // both platforms now use.
                Text(code).foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
            }
        }
        .font(.inter(17))
        text.padding(.horizontal, 22).frame(height: buttonHeight)
        #endif
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        // The reference app's tile, in its own colour while on and grey
        // while off, standing in for the button it is.
        let label = LineupIconTile(symbol: symbol, size: buttonHeight,
                                   tint: on ? nil : LineupIconTile.gray)
            .overlay(RoundedRectangle(cornerRadius: buttonHeight * 0.26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .modifier(MediaChromeFocus())
        TVSelectable(scale: LineupStyle.controlLift, action: action) { label }
        #else
        Button(action: action) {
            Image(systemName: on && ["heart", "eye"].contains(symbol) ? symbol + ".fill" : symbol)
                .font(.system(size: 21, weight: .semibold))
                .frame(width: buttonHeight, height: buttonHeight)
        }
        .buttonStyle(MobileLibraryDetailButtonStyle(selected: on))
        .accessibilityLabel(symbol == "heart" ? (on ? "Remove from Favorites" : "Add to Favorites")
            : symbol == "eye" ? (on ? "Mark Unwatched" : "Mark Watched") : "Shuffle Episodes")
        .accessibilityAddTraits(on && symbol != "shuffle" ? [.isSelected] : [])
        #endif
    }

    @ViewBuilder
    private var overview: some View {
        if let text = subject.overview, !text.isEmpty {
            Text(text)
                .font(.inter(.subheadline))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.76))
                .lineLimit(expandedOverview ? nil : 3)
                #if os(tvOS)
                .multilineTextAlignment(.leading)
                #else
                .multilineTextAlignment(.center).frame(maxWidth: .infinity, alignment: .center)
                #endif
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { expandedOverview.toggle() }
                }
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodesSection: some View {
        // A film has none, and an empty section would still cost the spacing
        // above it.
        if subject.isSeries {
            episodeList
        }
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(tvOS)
            seasonHeading.padding(.horizontal, horizontalPadding).lineupFocusRegion()
            #else
            PhoneShelfHeader(title: selectedSeason?.name ?? "Episodes", symbol: "list.number") {
                if seasons.count > 1 {
                    Button { setSeasonMenu(!seasonMenuOpen) } label: {
                        HStack(spacing: 3) {
                            Text("Seasons")
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .heavy, design: .rounded))
                                .rotationEffect(.degrees(seasonMenuOpen ? -180 : 0))
                        }
                        .font(.inter(14, .bold))
                        .foregroundStyle(LineupStyle.highlight)
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .anchorPreference(key: MediaSeasonMenuAnchor.self, value: .bounds) { $0 }
                    .accessibilityLabel("Seasons")
                    .accessibilityHint(seasonMenuOpen ? "Closes the list of seasons" : "Shows the list of seasons")
                }
            }
            #endif
            if loading {
                // Play and shuffle are both disabled until an episode is known,
                // so until then this page has nothing focusable on it at all.
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    .mediaFocusAnchor()
            } else if let error {
                Text(error).font(.inter(.footnote))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    .padding(.horizontal, horizontalPadding)
                    .mediaFocusAnchor()
            } else if episodes.isEmpty {
                Text("No episodes here yet.").font(.inter(.footnote))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    .padding(.horizontal, horizontalPadding)
                    .mediaFocusAnchor()
            } else {
                #if os(tvOS)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) {
                        ForEach(episodes) { episode in
                            MediaEpisodeCard(episode: episode,
                                             onPlay: { startingOver = false; chosen = episode },
                                             onSummary: { summaryItem = episode })
                            .frame(width: 420, alignment: .topLeading)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                .lineupFocusRegion()
                #else
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(episodes) { episode in
                            MediaEpisodeCard(episode: episode)
                                .lineupHoldMenu(episode.name, symbol: "tv",
                                                items: { media.episodeMenuItems(for: episode) }) {
                                    chosen = episode
                                }
                                .frame(width: 265)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                #endif
            }
        }
        .modifier(PhoneDetailPanel(bottom: 18))
    }

    // MARK: - More about this title

    @ViewBuilder
    private var trailersSection: some View {
        let trailers = (subject.remoteTrailers ?? []).compactMap { trailer -> (String, URL, URL?)? in
            guard let address = trailer.url, let url = URL(string: address),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (trailer.name ?? "Trailer", url, trailer.thumbnailURL)
        }
        if !trailers.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                detailSectionTitle("Trailers", symbol: "play.rectangle")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(trailers.indices, id: \.self) { index in
                            #if os(tvOS)
                            TVSelectable(action: { openURL(trailers[index].1) }) {
                                trailerCard(title: trailers[index].0, thumbnail: trailers[index].2)
                            }
                            #else
                            Link(destination: trailers[index].1) {
                                trailerCard(title: trailers[index].0, thumbnail: trailers[index].2)
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
            }
            .modifier(PhoneDetailPanel(bottom: 18))
        }
    }

    private func trailerCard(title: String, thumbnail: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(LineupStyle.surface)
                LineupArtView(url: thumbnail ?? media.backdropURL(for: subject), width: 320) { loaded in
                    if let loaded { loaded.resizable().scaledToFill() }
                    else { Color.clear }
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(15)
                    .background(.black.opacity(0.58), in: Circle())
            }
            .frame(width: trailerWidth, height: trailerWidth * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title).font(.inter(.subheadline, .semibold)).lineLimit(1)
        }
        .frame(width: trailerWidth, alignment: .leading)
    }

    @ViewBuilder
    private var castSection: some View {
        #if os(tvOS)
        let cast = (subject.people ?? []).filter { $0.type?.lowercased() == "actor" }
        #else
        let cast = LibraryCastMember.merged(provider: subject.people ?? [], credits: castCredits) {
            media.personImageURL(for: $0, of: subject)
        }
        #endif
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                detailSectionTitle("Cast", symbol: "person.2")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(cast) { person in
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    #if os(tvOS)
                                    RoundedRectangle(cornerRadius: 12).fill(LineupStyle.surface)
                                    LineupArtView(url: media.personImageURL(for: person, of: subject), width: 112) { loaded in
                                        if let image = loaded {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "person.fill")
                                                .font(.inter(.largeTitle))
                                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.35))
                                        }
                                    }
                                    #else
                                    MobileCastPortrait(member: person)
                                    #endif
                                }
                                .frame(width: castPortraitWidth, height: castPortraitHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(person.name).font(.inter(.caption, .semibold)).lineLimit(2)
                                if let role = person.role, !role.isEmpty {
                                    Text(role).font(.inter(.caption2)).lineLimit(2)
                                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                                }
                            }
                            .frame(width: castPortraitWidth, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                #if !os(tvOS)
                if !castCredits.isEmpty {
                    Link("Cast · TMDB", destination: URL(string: "https://www.themoviedb.org/")!)
                        .font(.inter(.caption2)).foregroundStyle(LineupPresentationStyle.secondary)
                        .padding(.horizontal, horizontalPadding)
                }
                #endif
            }
            .modifier(PhoneDetailPanel(bottom: 18))
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                // Named for what it holds, because a row of posters under a
                // bare "Related" does not say whether it is offering films or
                // series.
                #if os(tvOS)
                detailSectionTitle(subject.isSeries ? "Related Shows" : "Related Movies",
                                   symbol: "square.stack")
                #else
                detailSectionTitle(subject.isSeries ? "Similar Shows" : "Similar Movies", symbol: "square.stack")
                #endif
                #if !os(tvOS)
                MobileLibraryShelf(items: related, shape: .poster, discoversSources: true) { openSimilar($0) }
                Link("Suggestions · TMDB", destination: URL(string: "https://www.themoviedb.org/")!)
                    .font(.inter(.caption2)).foregroundStyle(LineupPresentationStyle.secondary)
                    .padding(.horizontal, horizontalPadding)
                #else
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: relatedItemSpacing) {
                        ForEach(related, id: \.libraryKey) { title in
                            Group {
                                #if os(tvOS)
                                TVSelectable(drawsFocusChrome: false, action: { pushed = title }) {
                                    MediaItemCard(item: title, shape: .poster)
                                }
                                .tvHoldMenu(title.name, symbol: "film") { media.tvCardChoices(for: title) }
                                #else
                                NavigationLink(destination: MediaBrowseDestination(item: title)) {
                                    MediaItemCard(item: title, shape: .poster)
                                }
                                .lineupFlatButton()
                                #endif
                            }
                            .frame(width: relatedCardWidth, alignment: .topLeading)
                        }
                    }
                    // Give the focused card's lift room without changing the
                    // top edge shared by every poster in the row.
                    .padding(.vertical, 8)
                }
                .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                // After a viewer scrolls far sideways there may be no control
                // geometrically above that poster. Treating the shelf as one
                // focus region lets an Up press return to the rows above.
                .lineupFocusRegion()
                #endif
            }
            .modifier(PhoneDetailPanel())
        }
    }

    /// A section's title: the television's large heading, the phone's
    /// panel header with its hairline.
    @ViewBuilder
    private func detailSectionTitle(_ title: String, symbol: String) -> some View {
        #if os(tvOS)
        TVShelfTitle(title: title, symbol: symbol)
            .padding(.horizontal, horizontalPadding)
        #else
        PhoneShelfHeader(title: title, symbol: symbol) { EmptyView() }
        #endif
    }

    private var relatedCardWidth: CGFloat {
        #if os(tvOS)
        // Match the poster shelves in MediaCatalogsScreen. The old 145-point
        // phone width made TV artwork cramped and visually uneven.
        230
        #else
        145
        #endif
    }

    private var relatedItemSpacing: CGFloat {
        #if os(tvOS)
        22
        #else
        14
        #endif
    }

    @ViewBuilder
    private var seasonHeading: some View {
        if seasons.count > 1 {
            #if os(tvOS)
            // A Menu renders through tvOS's own chrome, which is the bulk this
            // screen had left. Same treatment as Add Shelf: no Menu.
            TVSelectable(scale: LineupStyle.controlLift, action: { choosingSeason = true }) {
                HStack(spacing: 7) {
                    Text(selectedSeason?.name ?? "Episodes").font(sectionTitleFont)
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .modifier(MediaChromeSurface())
            }
            .tvChoices("Season", symbol: "list.number", isPresented: $choosingSeason) {
                seasons.map { season in
                    TVChoice(season.name, id: "\(season.id)", isSelected: season.id == selectedSeason?.id) {
                        Task { await loadSeason(season) }
                    }
                }
            }
            #else
            // The phone's episodes header has its own Seasons dropdown.
            Text(selectedSeason?.name ?? "Episodes").font(sectionTitleFont)
            #endif
        } else {
            Text(selectedSeason?.name ?? "Episodes").font(sectionTitleFont)
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        error = nil
        detail = nil
        nextUp = nil
        seasons = []; selectedSeason = nil; episodes = []
        pageReady = false
        #if os(tvOS)
        related = []
        preparedHero = nil
        #endif
        // A chart title has no server to ask: its page is TMDB's details.
        let loaded = media.isCatalogOnly(item) ? nil : try? await media.details(of: item)
        guard !Task.isCancelled else { return }
        detail = loaded ?? item
        favorite = (loaded ?? item).isFavorite || media.isLocalFavorite(loaded ?? item)
        let detailedItem = subject
        // While the viewer reads the page, so its VOD copies are waiting when
        // they choose to play.
        media.prepareProviderLookup(for: detailedItem)
        #if os(tvOS)
        // Build the complete first frame before focus enters the page. The
        // artwork is decoded once, rather than popping in through AsyncImage.
        async let relatedItems = media.related(to: detailedItem)
        let heroURLs = [media.backdropURL(for: detailedItem),
                        media.imageURL(for: detailedItem, width: 1280)].compactMap { $0 }
        async let heroData = Self.fetchHeroData(from: heroURLs)
        related = await relatedItems
        preparedHero = (await heroData).flatMap(UIImage.init(data:))
        #else
        // TMDB suggestions have their own task; they never hold up seasons,
        // episode/resume selection or the detail header.
        #endif
        // A film is the whole of itself: nothing underneath to go and get.
        guard subject.isSeries, !media.isCatalogOnly(item) else { loading = false; pageReady = true; return }
        do {
            let children = try await media.numberedChildren(of: item)
            let seasonList = children.filter { $0.type == "Season" }
            guard !seasonList.isEmpty else {
                // Some imported catalogs hang episodes straight off the item.
                seasons = []
                selectedSeason = nil
                episodes = children.filter(\.isPlayable)
                loading = false
                pageReady = true
                return
            }
            seasons = seasonList
            // Where the viewer is in the show -- an episode part-watched on
            // this device, else the one after the last they finished, else
            // the server's next one -- and the season it is in, so the page
            // opens where they were, with every other episode a choice away.
            nextUp = await media.resumeEpisode(in: subject)
            await loadSeason(seasonList.first { $0.indexNumber == nextUp?.parentIndexNumber } ?? seasonList[0])
            pageReady = true
        } catch {
            self.error = error.localizedDescription
            loading = false
            pageReady = true
        }
    }

    #if !os(tvOS)
    private func openSimilar(_ item: MediaItem) {
        guard openingSimilar == nil else { return }
        similarTask?.cancel()
        let request = UUID()
        similarLookupID = request
        openingSimilar = item.libraryKey
        similarTask = Task { @MainActor in
            defer { if similarLookupID == request { openingSimilar = nil } }
            let copy = await media.libraryCopy(of: item)
            guard !Task.isCancelled, similarLookupID == request else { return }
            if let copy { pushed = copy }
            else if media.seerr.isConnected, let raw = LibraryMetadataIdentity.ids(item)["tmdb"], let id = Int(raw) {
                similarRequest = SeerrTitleRoute(id: id, kind: item.isSeries ? .tv : .movie, title: item.name)
            } else { similarTitle = item.name; similarUnavailable = true }
        }
    }

    private func setSeasonMenu(_ open: Bool) {
        guard seasonMenuOpen != open else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
            seasonMenuOpen = open
        }
    }

    /// The seasons, hung from the button that opens them: under it where
    /// there is room, above it where it sits near the foot of the screen.
    private func seasonDropdown(from button: CGRect, in size: CGSize) -> some View {
        let width = min(260, size.width - 32)
        let x = min(max(16, button.maxX - width), size.width - width - 16)
        let below = size.height - button.maxY - 24
        let above = button.minY - 24
        let opensUp = below < 200 && above > below
        let sections = [MobileMenuSection(id: "seasons", items: seasons.map { season in
            MobileMenuItem(season.name, id: "\(season.id)", isSelected: season.id == selectedSeason?.id) {
                Task { await loadSeason(season) }
            }
        })]
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(MobileMenuGlass.backdrop)
                .contentShape(Rectangle())
                .onTapGesture { setSeasonMenu(false) }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                if opensUp { Spacer(minLength: 0) } else { Color.clear.frame(height: button.maxY + 6) }
                MobileDropdownPanel(title: "Seasons", symbol: "list.number", sections: sections,
                                    maxHeight: opensUp ? above : below) { setSeasonMenu(false) }
                    .frame(width: width)
                if opensUp { Color.clear.frame(height: size.height - button.minY + 6) } else { Spacer(minLength: 0) }
            }
            .padding(.leading, x)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .transition(.opacity)
    }
    #endif

    private func loadSeason(_ season: MediaItem) async {
        selectedSeason = season
        loading = true
        error = nil
        do { episodes = try await media.numberedChildren(of: season).filter(\.isPlayable) }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    // MARK: - Metrics

    private var detailGround: Color {
        #if os(tvOS)
        LineupStyle.background
        #else
        LineupPresentationStyle.ground
        #endif
    }

    private var detailText: Color {
        #if os(tvOS)
        LineupStyle.lightPurple
        #else
        LineupPresentationStyle.text
        #endif
    }

    private var castPortraitWidth: CGFloat {
        #if os(tvOS)
        112
        #else
        96
        #endif
    }

    private var castPortraitHeight: CGFloat {
        #if os(tvOS)
        150
        #else
        128
        #endif
    }

    #if !os(tvOS)
    private var castRequestKey: String {
        let ids = LibraryMetadataIdentity.ids(subject)
        return ([subject.libraryKey] + ids.keys.sorted().map { "\($0):\(ids[$0] ?? "")" }).joined(separator: "|")
    }
    #endif

    private var heroURL: URL? {
        #if os(tvOS)
        media.backdropURL(for: subject) ?? media.imageURL(for: subject, width: 1280)
        #else
        media.backdropURL(for: subject, width: 1280) ?? media.imageURL(for: subject, width: 900)
        #endif
    }
    /// Wider than any iPhone, so the hero is never decoded short of the screen
    /// it fills. It is one picture on one page; the saving is not worth a
    /// measurement pass to get it exact.
    private var heroWidth: CGFloat { 460 }
    #if os(tvOS)
    nonisolated private static func fetchHeroData(from urls: [URL]) async -> Data? {
        for url in urls {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode), !data.isEmpty { return data }
        }
        return nil
    }
    #endif
    private var heroRatio: CGFloat {
        #if os(tvOS)
        // Leave the first action inside the initial focus viewport. At 20:9
        // the focused Play button was below the fold, so tvOS auto-scrolled
        // the whole page on entry and clipped the tab/navigation chrome.
        3
        #else
        16 / 10
        #endif
    }
    /// How far the page's text reaches up into the fading art. Negative: it is
    /// closing the gap the stack would otherwise leave.
    private var contentRise: CGFloat {
        #if os(tvOS)
        -110
        #else
        -36
        #endif
    }
    /// Feather the landscape backdrop into the detail page's title block.
    private var fadeHeight: CGFloat {
        #if os(tvOS)
        250
        #else
        120
        #endif
    }
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        70
        #else
        LineupPanelStyle.inset
        #endif
    }
    private var buttonHeight: CGFloat {
        #if os(tvOS)
        50
        #else
        50
        #endif
    }
    private var trailerWidth: CGFloat {
        #if os(tvOS)
        360
        #else
        260
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .inter(40, .heavy)
        #else
        .inter(.title, .heavy)
        #endif
    }
    private var sectionTitleFont: Font {
        #if os(tvOS)
        .inter(24, .heavy)
        #else
        .inter(.title3, .heavy)
        #endif
    }
}

#if os(tvOS)
/// Detail actions keep their pill silhouette at all times and communicate
/// focus with a clean fill, never with a second rectangular frame around the
/// button's bounds.
struct TVMediaActionSurface: ViewModifier {
    @Environment(\.lineupTVSelectableFocused) private var focused

    func body(content: Content) -> some View {
        content
            .foregroundStyle(LineupStyle.lightPurple)
            .background(Color.black.opacity(0.58), in: Capsule())
            .lineupFocusLayer(focused, in: Capsule())
            .lineupShadow(.lifted, on: focused)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }
}
#endif

/// An episode card says which episode it is and what happens in it, so a viewer
/// picks by the description rather than by guessing from a still.
struct MediaEpisodeCard: View {
    @Environment(MediaLibrary.self) private var media
    #if !os(tvOS)
    @Environment(\.displayScale) private var displayScale
    #endif
    #if os(tvOS)
    @State private var artworkFocused = false
    #endif
    private let originalEpisode: MediaItem
    private var episode: MediaItem { media.displayItem(originalEpisode) }
    var onPlay: () -> Void = {}
    var onSummary: () -> Void = {}

    init(episode: MediaItem, onPlay: @escaping () -> Void = {}, onSummary: @escaping () -> Void = {}) {
        originalEpisode = episode
        self.onPlay = onPlay
        self.onSummary = onSummary
    }

    var body: some View {
        let playback = playbackPresentation
        return VStack(alignment: .leading, spacing: 7) {
            #if os(tvOS)
            TVSelectable(drawsFocusChrome: false, action: onPlay,
                         onFocusChange: { artworkFocused = $0 }) {
                artwork(playback: playback)
                    .frame(height: 236.25)
            }
            .tvHoldMenu(episode.name, symbol: "tv") { media.tvEpisodeChoices(for: episode) }
            .accessibilityLabel("Play \(episode.name)")
            #else
            artwork(playback: playback)
                .aspectRatio(16 / 9, contentMode: .fit)
            #endif
            if let label = episode.episodeCode ?? episode.episodeLabel {
                Text(label).font(.inter(.caption, .semibold))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
            }
            #if os(tvOS)
            Text(episode.name).font(.inter(.subheadline, .bold)).lineLimit(2, reservesSpace: true)
            #else
            Text(episode.name).font(.inter(.subheadline, .bold)).lineLimit(2, reservesSpace: true)
            #endif
            if let overview = episode.overview, !overview.isEmpty {
                #if os(tvOS)
                TVMediaSummaryPreview(text: overview, compact: true, action: onSummary)
                    .tvHoldMenu(episode.name, symbol: "tv") { media.tvEpisodeChoices(for: episode) }
                #else
                Text(overview).font(.inter(.caption))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                #endif
            }
            if !footer.isEmpty {
                Text(footer).font(.inter(.caption2))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
            }
            LibraryMetadataCredit(item: episode, interactive: false)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(LineupStyle.lightPurple)
        .task(id: media.metadataRequestKey(for: originalEpisode)) {
            await media.resolveMetadata(for: originalEpisode)
        }
    }

    private func artwork(playback: MediaCardPlayback?) -> some View {
        artworkFrame(playback: playback)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .lineupFocusLayer(episodeArtworkIsFocused, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if playback?.watched == true {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(LineupStyle.background)
                            .frame(width: 26, height: 26)
                            .background(LineupStyle.lightPurple, in: Circle())
                            .padding(8)
                    }
                }
    }

    @ViewBuilder private func artworkFrame(playback: MediaCardPlayback?) -> some View {
        #if os(tvOS)
        TVMediaArtwork(playback: playback) { picture }
        #else
        Color.clear.frame(maxWidth: .infinity)
            .overlay { picture }
            .overlay(alignment: .bottom) {
                if let playback { MediaArtworkProgress(playback: playback) }
            }
        #endif
    }

    private var picture: some View {
        ZStack {
            LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            #if os(tvOS)
            LineupArtView(url: media.imageURL(for: episode, width: 640), width: 360) { loaded in
                if let image = loaded { image.resizable().scaledToFill() }
                else { Image(systemName: "film.fill").font(.inter(.largeTitle)) }
            }
            #else
            let size = MobileLibraryArtworkSize(width: 265, ratio: 16 / 9, scale: displayScale)
            MobileLibraryArtView(url: media.imageURL(for: episode, width: size.width), pixels: size.longestEdge) { loaded in
                if let image = loaded { image.resizable().scaledToFill() }
                else { Image(systemName: "film.fill").font(.inter(.largeTitle)) }
            }
            #endif
        }
    }

    private var episodeArtworkIsFocused: Bool {
        #if os(tvOS)
        artworkFocused
        #else
        false
        #endif
    }

    private var playbackPresentation: MediaCardPlayback? {
        media.cardPlayback(for: episode, asShow: false)
    }

    private var footer: String {
        [episode.formattedAirDate, episode.formattedRuntime]
            .compactMap { $0 }.joined(separator: "  \u{00B7}  ")
    }
}

struct MediaPlayableCard: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.playMedia) private var playMedia
    let item: MediaItem
    var shape: MediaArtShape = .poster
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Only for a card shown outside the Library tab, which has no tab to
    /// hand the title to.
    @State private var choosingSource = false

    var body: some View {
        #if os(tvOS)
        TVSelectable(drawsFocusChrome: false, action: choose, onFocusChange: onFocusChange) {
            MediaItemCard(item: item, shape: shape)
        }
            .tvHoldMenu(item.name, symbol: item.type == "Episode" ? "tv" : "film") { media.tvCardChoices(for: item) }
            .lineupFullScreenCover(isPresented: $choosingSource) {
                MediaSourcePicker(item: item)
            }
        #else
        MediaItemCard(item: item, shape: shape)
            .lineupHoldMenu(item.name, symbol: item.type == "Episode" ? "tv" : "film",
                            items: { media.cardMenuItems(for: item) }, action: choose)
            .lineupSheet(isPresented: $choosingSource) {
                MediaSourcePicker(item: item)
            }
        #endif
    }

    /// The Library tab opens the streams, so the player outlives this card.
    private func choose() {
        if let playMedia { playMedia(item) } else { choosingSource = true }
    }
}

#if !os(tvOS)
extension MediaLibrary {
    /// What a touch held on a Library card offers: leaving Continue
    /// Watching, and for an episode, watched and favorite.
    func cardMenuItems(for item: MediaItem) -> [MobileMenuItem] {
        guard !isCatalogOnly(item) else { return [] }
        var items: [MobileMenuItem] = []
        if isInContinueWatching(item) {
            items.append(MobileMenuItem("Remove from Continue Watching", symbol: "rectangle.stack.badge.minus",
                                        isDestructive: true) {
                self.removeFromContinueWatching(item)
            })
        }
        if item.type == "Episode" { items += episodeMenuItems(for: item) }
        if let collections = collectionMenu(for: item) { items.append(collections) }
        return items
    }

    /// An episode's own: watched, and the Favorites library.
    func episodeMenuItems(for episode: MediaItem) -> [MobileMenuItem] {
        let watched = isWatched(episode)
        let favorite = isLocalFavorite(episode)
        return [
            MobileMenuItem(watched ? "Remove from Watched" : "Mark Watched",
                           symbol: watched ? "eye.slash" : "eye") {
                Task { await self.setEpisodePlayedAndAdvance(!watched, for: episode) }
            },
            MobileMenuItem(favorite ? "Remove from Favorites" : "Add to Favorites",
                           symbol: favorite ? "heart.slash" : "heart") {
                self.setLocalFavorite(!favorite, for: episode)
                Task { await self.setFavorite(!favorite, for: episode) }
            }
        ]
    }
}
#endif

#if os(tvOS)
extension MediaLibrary {
    /// What holding Select on a Library card offers: leaving Continue
    /// Watching, and for an episode, watched and favorite. One list, whether
    /// the card opens a page or the streams.
    func tvCardChoices(for item: MediaItem) -> [TVChoice] {
        var choices: [TVChoice] = []
        if isInContinueWatching(item) {
            choices.append(TVChoice("Remove from Continue Watching", symbol: "rectangle.stack.badge.minus",
                                    isDestructive: true) {
                self.removeFromContinueWatching(item)
            })
        }
        if item.isPlayable { choices += tvEpisodeChoices(for: item) }
        if let collections = tvCollectionChoice(for: item) { choices.append(collections) }
        return choices
    }

    /// Movies and episodes both offer watched status and Favorites.
    func tvEpisodeChoices(for episode: MediaItem) -> [TVChoice] {
        let watched = isWatched(episode)
        let favorite = isLocalFavorite(episode)
        return [
            TVChoice(watched ? "Mark Unwatched" : "Mark Watched", symbol: watched ? "eye.slash" : "eye") {
                Task { await self.setEpisodePlayedAndAdvance(!watched, for: episode) }
            },
            TVChoice(favorite ? "Remove from Favorites" : "Add to Favorites",
                     symbol: favorite ? "heart.slash" : "heart") {
                self.setLocalFavorite(!favorite, for: episode)
                Task { await self.setFavorite(!favorite, for: episode) }
            }
        ]
    }
}
#endif
