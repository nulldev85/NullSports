import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// A full-bleed top-ten carousel sourced from the catalog chosen in Account.
/// It advances gently when left alone. Changing the page by touch restarts the
/// four-second interval, so it never fights a swipe or immediately skips the
/// title the viewer deliberately chose.
struct MediaLibraryHero: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let catalog: MediaCatalog
    let onOpen: (MediaItem) -> Void
    #if !os(tvOS)
    let scrollActivity: MobileLibraryScrollActivity
    #endif
    @State private var index = 0
    @State private var isDragging = false
    @State private var isVisible = false
    /// Each title's ratings once found, so a slide shown again has its chips.
    @State private var ratings: [String: MediaRatings] = [:]

    private var items: [MediaItem] {
        MediaHeroCatalogSelection.featuredItems(in: catalog).map { media.displayItem($0) }
    }

    var body: some View {
        Group {
            #if os(tvOS)
            if !items.isEmpty {
                heroSlide(item: items[min(index, items.count - 1)])
                    .overlay(alignment: .bottom) { pageIndicator }
                    .accessibilityAction(named: Text("Next title")) { move(1) }
                    .accessibilityAction(named: Text("Previous title")) { move(-1) }
            }
            #else
            if !items.isEmpty {
                GeometryReader { viewport in
                    let current = min(index, items.count - 1)
                    let rotates = isVisible && scenePhase == .active && !voiceOver
                        && !isDragging && !scrollActivity.isActive
                    let pixels = LineupArt.pixels(for: viewport.size.width)
                    // Two overlapping slides fade together, including last to
                    // first. A page controller otherwise jumps across the list.
                    ZStack {
                        heroSlide(item: items[current])
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .id(items[current].libraryKey)
                            .transition(.opacity)
                    }
                    .animation(LibraryHeroRotation.animation(reduceMotion: reduceMotion),
                               value: items[current].libraryKey)
                    .overlay(alignment: .bottom) { pageIndicator }
                    .accessibilityAction(named: Text("Next title")) { move(1) }
                    .accessibilityAction(named: Text("Previous title")) { move(-1) }
                    .gesture(MobileLibraryHeroSwipe(onInteractionChanged: { isDragging = $0 },
                                                    onSwipe: move))
                    .task(id: LibraryHeroRotationKey(items: items.map(\.libraryKey), index: current,
                                                    enabled: rotates, pixels: pixels)) {
                        guard rotates else { return }
                        await rotate(pixels: pixels)
                    }
                    .task(id: LibraryHeroRotationKey(items: items.map(\.libraryKey), index: current,
                                                    enabled: isVisible && scenePhase == .active,
                                                    pixels: pixels)) {
                        let candidates = items
                        guard isVisible, scenePhase == .active, candidates.count > 1 else { return }
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                        // Only the next two hero titles, never every Library
                        // poster. Existing API/image coalescers bound the work.
                        await withTaskGroup(of: Void.self) { group in
                            for step in 1...min(2, candidates.count - 1) {
                                let upcoming = candidates[(current + step) % candidates.count]
                                group.addTask(priority: .utility) { await media.warmTitleLogos(for: upcoming) }
                            }
                        }
                    }
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity)
        #if os(tvOS)
        .frame(height: heroHeight)
        .clipped()
        #else
        // Match the detail page's portrait artwork instead of cropping a
        // landscape backdrop into the phone's hero.
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        #endif
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; isDragging = false }
        #if os(tvOS)
        // Any focused control inside the hero participates in the same
        // carousel. A left/right press therefore changes the feature directly
        // instead of first requiring focus to land on a tiny chevron.
        .onMoveCommand { direction in
            switch direction {
            case .left: move(-1)
            case .right: move(1)
            default: break
            }
        }
        #endif
        .onChange(of: catalog.id) { _, _ in index = 0 }
        .onChange(of: items.count) { _, count in
            if count == 0 { index = 0 }
            else { index = min(index, count - 1) }
        }
        // The title on screen, then the one after it, so the next slide
        // arrives with its chips already found.
        .task(id: items.indices.contains(index) ? media.metadataRequestKey(for: items[index]) : "") {
            guard !items.isEmpty else { return }
            let current = min(index, items.count - 1)
            for offset in [current, (current + 1) % items.count] {
                let item = items[offset]
                await media.resolveMetadata(for: item)
                guard !Task.isCancelled else { return }
                guard ratings[item.libraryKey] == nil else { continue }
                let found = await media.ratings(for: item)
                guard !Task.isCancelled else { return }
                ratings[item.libraryKey] = found
            }
        }
    }

    private func heroSlide(item: MediaItem) -> some View {
        GeometryReader { slide in
            let contentWidth = max(0, slide.size.width - heroHorizontalPadding * 2)
            let contentHeight = max(0, slide.size.height - heroTopPadding - heroBottomPadding)
            let readableWidth = min(copyWidth, contentWidth)

            ZStack(alignment: .bottomLeading) {
                ZStack {
                    LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    LineupArtView(url: artworkURL(for: item),
                                  // Decode for the resting viewport. Pulling
                                  // transforms the cached picture, without
                                  // changing the loader's pixel/cache key.
                                  width: slide.size.width) { image in
                        if let image { image.resizable().scaledToFill() }
                        else { Color.clear }
                    }
                }
                .frame(width: slide.size.width, height: slide.size.height)
                #if !os(tvOS)
                .mobileLibraryArtworkZoom()
                #endif
                #if os(tvOS)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.9), location: 0),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .clear, location: 0.86)
                ], startPoint: .leading, endPoint: .trailing)
                // Keep the picture alive almost to the first shelf, then finish
                // on the exact Library background at the seam. The older fade
                // became opaque too early and left a dead band above Continue
                // Watching even though the artwork itself filled the hero.
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.72),
                    .init(color: .black.opacity(0.12), location: 0.9),
                    .init(color: LineupStyle.background.opacity(0.25), location: 0.98),
                    .init(color: LineupStyle.background, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                #else
                // A long portrait fade keeps the upper artwork clear, then
                // blends behind the copy into the first shelf's background.
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.38),
                    .init(color: LineupStyle.background.opacity(0.08), location: 0.52),
                    .init(color: LineupStyle.background.opacity(0.45), location: 0.67),
                    .init(color: LineupStyle.background.opacity(0.88), location: 0.84),
                    .init(color: LineupStyle.background, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                #endif

                VStack(alignment: .center, spacing: heroSpacing) {
                    Spacer(minLength: 0)

                    #if os(tvOS)
                    Text(item.name)
                        .font(.inter(titleSize, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: readableWidth, alignment: .center)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    #else
                    MobileFanartTitle(item: item, width: readableWidth,
                                      height: min(100, titleSize * 2.2), alignment: .center) {
                        Text(item.name)
                            .font(.inter(titleSize, .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: readableWidth, alignment: .center)
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    }
                    #endif

                    if let shown = ratings[item.libraryKey] ?? media.knownRatings(for: item), !shown.isEmpty {
                        MediaRatingChips(ratings: shown)
                    } else {
                        Color.clear.frame(height: MediaRatingMetrics.height)
                    }

                    if !metadata(for: item).isEmpty {
                        Text(metadata(for: item).joined(separator: "  ·  "))
                            .font(.inter(metaSize, .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .frame(width: readableWidth, alignment: .center)
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.inter(overviewSize))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(overviewLines)
                            .multilineTextAlignment(.center)
                            .frame(width: readableWidth, alignment: .center)
                    }

                    #if os(tvOS)
                    MediaHeroButton(title: item.hasDetailPage ? "Details" : "Play",
                                    symbol: item.hasDetailPage ? "info.circle.fill" : "play.fill") {
                        onOpen(item)
                    }
                    .frame(width: min(buttonMaxWidth, contentWidth), alignment: .center)
                    #endif
                }
                // This frame is explicit rather than an ideal/max width. A
                // long title can wrap inside it, but can never make a TabView
                // page wider and move its leading edge off screen again.
                .frame(width: contentWidth, height: contentHeight, alignment: .bottom)
                .padding(.horizontal, heroHorizontalPadding)
                .padding(.top, heroTopPadding)
                .padding(.bottom, heroBottomPadding)
            }
            .frame(width: slide.size.width, height: slide.size.height)
            #if os(tvOS)
            .clipped()
            #endif
        }
        .contentShape(Rectangle())
        #if !os(tvOS)
        // A horizontal swipe changes title; a tap opens it. The artwork is
        // the iPhone affordance, without a redundant Details button.
        .onTapGesture { onOpen(item) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.hasDetailPage ? "View details for \(item.name)" : "Play \(item.name)")
        #endif
    }

    /// The year, the genres and the running time, under the ratings.
    private func metadata(for item: MediaItem) -> [String] {
        [item.productionYear.map(String.init),
         item.genres?.prefix(3).joined(separator: ", "),
         item.formattedRuntime]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    private func artworkURL(for item: MediaItem) -> URL? {
        #if os(tvOS)
        media.backdropURL(for: item, width: artWidth) ?? media.imageURL(for: item, width: artWidth)
        #else
        media.imageURL(for: item, width: artWidth) ?? media.backdropURL(for: item, width: artWidth)
        #endif
    }

    private func rotate(pixels: Int) async {
        let candidates = items
        guard candidates.count > 1 else { return }
        let current = min(index, candidates.count - 1)
        let next = (current + 1) % candidates.count
        for offset in [current, next, (next + 1) % candidates.count] {
            LineupArt.prefetch(artworkURL(for: candidates[offset]), pixels: pixels)
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: LibraryHeroRotation.interval) } catch { return }
            guard !Task.isCancelled else { return }
            let nextArtwork = artworkURL(for: candidates[next])
            guard LineupArt.isResolved(nextArtwork, pixels: pixels) else {
                // A transient error isn't cached; try again without dropping
                // the picture already on screen or duplicating an active load.
                LineupArt.prefetch(nextArtwork, pixels: pixels)
                continue
            }
            move(1)
            return
        }
    }

    #if os(tvOS)
    private var artWidth: Int { 1800 }
    // From the physical top edge through the tab-bar chrome and down to the
    // first shelf, this gives tvOS the same cinematic proportion as iPhone.
    private var heroHeight: CGFloat { 700 }
    private var heroHorizontalPadding: CGFloat { 72 }
    private var heroTopPadding: CGFloat { 40 }
    private var heroBottomPadding: CGFloat { 76 }
    private var heroSpacing: CGFloat { 10 }
    private var titleSize: CGFloat { 48 }
    private var metaSize: CGFloat { 16 }
    private var overviewSize: CGFloat { 17 }
    private var overviewLines: Int { 2 }
    private var copyWidth: CGFloat { 720 }
    private var buttonMaxWidth: CGFloat { 190 }
    #else
    private var artWidth: Int { 1100 }
    private var heroHorizontalPadding: CGFloat { 22 }
    // Artwork runs behind the status/navigation area; copy begins below it.
    private var heroTopPadding: CGFloat { 86 }
    private var heroBottomPadding: CGFloat { 58 }
    private var heroSpacing: CGFloat { 7 }
    private var titleSize: CGFloat { 34 }
    private var metaSize: CGFloat { 13 }
    private var overviewSize: CGFloat { 14 }
    private var overviewLines: Int { 2 }
    private var copyWidth: CGFloat { 390 }
    private var buttonMaxWidth: CGFloat { 145 }
    #endif

    private var pageIndicator: some View {
        HStack(spacing: 5) {
            ForEach(items.indices, id: \.self) { page in
                Capsule()
                    .fill(.white.opacity(page == index ? 0.92 : 0.3))
                    .frame(width: page == index ? 18 : 5, height: 5)
            }
        }
        #if os(tvOS)
        .padding(.bottom, 28)
        #else
        .padding(.bottom, 18)
        #endif
        .animation(.easeOut(duration: 0.2), value: index)
        .accessibilityHidden(true)
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        withAnimation(LibraryHeroRotation.animation(reduceMotion: reduceMotion)) {
            index = (min(index, items.count - 1) + delta + items.count) % items.count
        }
    }
}

struct MediaHeroButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, action: action) { label }
        #else
        Button(action: action) { label }.lineupFlatButton()
        #endif
    }

    private var label: some View {
        Label(title, systemImage: symbol)
            .font(.inter(buttonFont, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, buttonInset)
            .frame(height: buttonHeight)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
    }

    #if os(tvOS)
    private var buttonFont: CGFloat { 17 }
    private var buttonInset: CGFloat { 18 }
    private var buttonHeight: CGFloat { 50 }
    #else
    private var buttonFont: CGFloat { 14 }
    private var buttonInset: CGFloat { 13 }
    private var buttonHeight: CGFloat { 42 }
    #endif
}

/// Account owns personalization; the Library hero only presents the result.
/// Keeping the choice here also gives it enough room to explain how many of a
/// shelf's titles will be used instead of putting a settings icon over art.
struct LibraryHeroSettingsView: View {
    @Environment(MediaLibrary.self) private var media

    /// Something the hero can feature: a shelf already on the Library, or
    /// any list the Library could add as one.
    private struct Choice: Identifiable {
        enum Pick {
            case shelf(MediaCatalog)
            case list(LibraryHeroSource)
        }
        let id: String
        let title: String
        let detail: String?
        let pick: Pick
    }

    private struct ChoiceGroup: Identifiable {
        let id: String
        let title: String
        let detail: String?
        /// The logo of the server the group is named for.
        var brand: MediaServerBrand? = nil
        let choices: [Choice]
    }

    /// The shelves first, then every list Add Shelf offers, grouped the way
    /// it groups them.
    private var groups: [ChoiceGroup] {
        var groups: [ChoiceGroup] = []
        let shelves = media.catalogs.filter { !$0.items.isEmpty }.map { catalog in
            Choice(id: catalog.id, title: media.shelfTitle(catalog),
                   detail: [featured(catalog.items.count), media.serverName(for: catalog)]
                       .compactMap { $0 }.joined(separator: " · "),
                   pick: .shelf(catalog))
        }
        groups.append(ChoiceGroup(id: "shelves", title: "YOUR SHELVES", detail: "Already in the Library",
                                  choices: shelves))
        let several = media.profiles.count > 1
        for server in media.profiles {
            let owner = several ? " · " + server.name.uppercased() : ""
            let brand = several ? MediaServerBrand.of(server) : nil
            groups.append(ChoiceGroup(id: server.id.uuidString + "|libraries", title: "LIBRARIES" + owner,
                                      detail: nil, brand: brand,
                                      choices: media.availableLibraries(on: server).map(rootChoice)))
            groups.append(ChoiceGroup(id: server.id.uuidString + "|catalogs", title: "IMPORTED CATALOGS" + owner,
                                      detail: nil, brand: brand,
                                      choices: media.availableCatalogs(on: server).map(rootChoice)))
        }
        if let name = media.providerVOD.profile?.name {
            let categories = media.availableProviderShelves
            groups.append(ChoiceGroup(id: "provider|films", title: "MOVIES · " + name.uppercased(),
                                      detail: "Film categories from your IPTV provider",
                                      choices: categories.films.map(rootChoice)))
            groups.append(ChoiceGroup(id: "provider|shows", title: "SERIES · " + name.uppercased(),
                                      detail: "Series categories from your IPTV provider",
                                      choices: categories.shows.map(rootChoice)))
        }
        for section in MDBListCatalogSection.allCases {
            let lists = media.availableMDBListCatalogs.filter { $0.section == section }
            groups.append(ChoiceGroup(id: "mdblist|" + section.rawValue, title: section.title,
                                      detail: section.detail,
                                      choices: lists.map { list in
                                          Choice(id: list.shelfID, title: list.name,
                                                 detail: list.itemCount.map { "\($0) list titles" },
                                                 pick: .list(LibraryHeroSource(mdbListID: list.id, name: list.name)))
                                      }))
        }
        return groups.filter { !$0.choices.isEmpty }
    }

    private func rootChoice(_ root: MediaItem) -> Choice {
        Choice(id: MediaCatalog.id(for: root), title: root.name,
               detail: root.childCount.map { $0 == 1 ? "1 title" : "\($0) titles" },
               pick: .list(LibraryHeroSource(root: root, name: root.name)))
    }

    private func featured(_ count: Int) -> String {
        let shown = min(10, count)
        return "\(shown) featured title\(shown == 1 ? "" : "s")"
    }

    private func choose(_ choice: Choice) {
        switch choice.pick {
        case .shelf(let catalog): media.selectHeroCatalog(catalog)
        case .list(let source): Task { await media.selectHeroSource(source) }
        }
    }

    /// The lists that are read on request, so every one is offered.
    private func loadSources() async {
        async let mdbList: Void = media.loadMDBListIntegration()
        async let provider: Void = media.loadProviderCatalog()
        _ = await (mdbList, provider)
    }

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageTitle(eyebrow: "Library", title: "Library Hero",
                          detail: "Choose any list. Its first ten titles fill the Library hero.")
                if groups.isEmpty {
                    LineupUnavailableView("No Lists", systemImage: "rectangle.stack.badge.plus",
                        description: Text("Add a media server, then choose a list here."))
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .mediaFocusAnchor()
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 14) {
                            groupHeading(group)
                            ForEach(group.choices) { choice in
                                TVSelectable(scale: LineupStyle.controlLift, action: { choose(choice) }) {
                                    choiceRow(choice)
                                }
                            }
                        }
                        .lineupFocusRegion()
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 70).padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .task { await loadSources() }
        #else
        List {
            if groups.isEmpty {
                LineupUnavailableView("No Lists", systemImage: "rectangle.stack.badge.plus",
                    description: Text("Add a media server, then choose a list here."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.choices) { choice in
                            Button { choose(choice) } label: { choiceRow(choice) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        groupHeading(group)
                    } footer: {
                        if group.id == groups.first?.id {
                            Text("The first ten titles of the list you choose become the swipeable Library hero.")
                        }
                    }
                    .listRowBackground(LineupPanelStyle.listCard)
                    .listRowSeparatorTint(LineupPanelStyle.listSeparator)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LineupPanelStyle.listGround)
        .navigationTitle("Library Hero")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSources() }
        #endif
    }

    private func groupHeading(_ group: ChoiceGroup) -> some View {
        HStack(spacing: 7) {
            if let brand = group.brand {
                MediaServerLogo(brand: brand).frame(width: headingLogoSize, height: headingLogoSize)
            }
            #if os(tvOS)
            Text(group.title)
                .font(.inter(headingSize, .heavy)).tracking(1.4)
                .foregroundStyle(LineupPresentationStyle.text.opacity(0.5))
                .lineLimit(1)
            #else
            Text(group.title).modifier(LineupGroupHeading()).lineLimit(1)
            #endif
        }
        .textCase(nil)
    }

    private func choiceRow(_ choice: Choice) -> some View {
        let selected = media.heroCatalog?.id == choice.id
        let busy = media.loadingHeroSource == choice.id
        return HStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: rowSymbolSize, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? LineupStyle.highlight : LineupPresentationStyle.secondary)
                .frame(width: rowSymbolFrame)
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.title).font(.inter(rowTitleSize, .semibold)).lineLimit(1)
                if let detail = choice.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.inter(rowDetailSize))
                        .foregroundStyle(LineupPresentationStyle.text.opacity(0.58))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if busy {
                ProgressView().controlSize(.small)
            } else if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: checkSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(LineupStyle.highlight)
                    .accessibilityLabel("Selected")
            }
        }
        .foregroundStyle(LineupPresentationStyle.text)
        .padding(.horizontal, rowHorizontalPadding)
        .frame(minHeight: rowHeight)
        #if os(tvOS)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(LineupStyle.line, lineWidth: 1))
        #endif
        .contentShape(Rectangle())
    }

    #if os(tvOS)
    private var rowSymbolSize: CGFloat { 25 }
    private var rowSymbolFrame: CGFloat { 42 }
    private var rowTitleSize: CGFloat { 21 }
    private var rowDetailSize: CGFloat { 15 }
    private var checkSize: CGFloat { 24 }
    private var rowHorizontalPadding: CGFloat { 24 }
    private var rowHeight: CGFloat { 82 }
    private var headingSize: CGFloat { 13 }
    private var headingLogoSize: CGFloat { 16 }
    #else
    private var rowSymbolSize: CGFloat { 20 }
    private var rowSymbolFrame: CGFloat { 30 }
    private var rowTitleSize: CGFloat { 16 }
    private var rowDetailSize: CGFloat { 13 }
    private var checkSize: CGFloat { 20 }
    private var rowHorizontalPadding: CGFloat { 0 }
    private var rowHeight: CGFloat { 58 }
    private var headingSize: CGFloat { 11 }
    private var headingLogoSize: CGFloat { 13 }
    #endif
}
