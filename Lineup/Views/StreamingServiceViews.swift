import QuartzCore
import SwiftUI
import Observation

// MARK: - The poster

/// A service's poster on the Streaming Services row: its official mark on
/// its own colour, and behind it the titles it has on that the viewer can
/// play, each drifting slowly across the card and giving way to the next.
/// Until any of that art is in hand, or where there is none, the card is
/// the flat colour and the mark alone.
///
/// Every poster keeps to one clock. On the phone, which title is up and how
/// far along its drift it is follow from the time alone, so a poster
/// scrolled away and back, rebuilt, or restarted is exactly where it would
/// have been, and the posters in a row change in a steady, even turn. Art is
/// fetched ahead, a change only ever goes to a picture already made, and
/// once a poster has art it never drops back to the flat card.
struct StreamingServicePoster: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var focused
    #endif
    let service: StreamingService

    @State private var reel = StreamingPosterReel()
    /// The picture on show, kept until another is ready to take its place.
    @State private var loaded: StreamingPosterPicture?

    /// Each service as a card in its own colour, the logo on it in the one
    /// colour the service sets it in on that ground.
    private enum LogoInk { case white, black, original }

    private struct Brand {
        let fill: Color
        let ink: LogoInk
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    private static func brand(_ id: String) -> Brand {
        switch id {
        case "netflix": Brand(fill: hex(0xE50914), ink: .white)
        case "prime": Brand(fill: hex(0x1A98FF), ink: .white)
        case "disney": Brand(fill: hex(0x0063E5), ink: .white)
        case "hbomax": Brand(fill: hex(0x002BE7), ink: .white)
        // Apple's own black would vanish into the panel it sits on; its
        // graphite keeps the card a card.
        case "appletv": Brand(fill: hex(0x3A3A3C), ink: .white)
        case "paramount": Brand(fill: hex(0x0064FF), ink: .white)
        // Hulu sets its mark in black on its green.
        case "hulu": Brand(fill: hex(0x1CE783), ink: .black)
        // Peacock is black, and its feathers keep their colours.
        case "peacock": Brand(fill: hex(0x000000), ink: .original)
        default: Brand(fill: LineupPanelStyle.well, ink: .white)
        }
    }

    @ViewBuilder
    private func logo(_ ink: LogoInk) -> some View {
        switch ink {
        case .original:
            Image(service.logoAsset).resizable().interpolation(.high)
        case .white:
            Image(service.logoAsset).renderingMode(.template).resizable().interpolation(.high)
                .foregroundStyle(.white)
        case .black:
            Image(service.logoAsset).renderingMode(.template).resizable().interpolation(.high)
                .foregroundStyle(Color(red: 0.016, green: 0.016, blue: 0.02))
        }
    }

    /// How often one title gives way to the next, and how long the fade
    /// takes. A drift runs longer than a title is up, so a picture is still
    /// moving under the next one as that fades in.
    static let interval: Double = 7
    static let fade: Double = 1.4
    static let span: Double = 10

    /// The phone moves every poster on screen. The television moves only the
    /// one in focus, so a row of them is calm until one is chosen; the rest
    /// hold their picture exactly where it was.
    private var motion: StreamingPosterCanvas.Motion {
        if reduceMotion { return .still }
        #if os(tvOS)
        return focused ? .running : .paused
        #else
        return .running
        #endif
    }

    /// Where this service's posters fall in the row's turn: the services
    /// change a quarter of an interval apart, never all at once.
    private var order: Int { StreamingService.all.firstIndex(where: { $0.id == service.id }) ?? 0 }

    var body: some View {
        GeometryReader { proxy in
            let brand = Self.brand(service.id)
            let urls = reel.urls(for: service, in: media)
            let pixels = Self.pixels(for: proxy.size, scale: displayScale)
            // The cache is asked here as well, so a poster coming back into
            // view draws its picture in its very first frame.
            let picture = urls.isEmpty ? nil
                : loaded ?? StreamingPosterSchedule.opening(urls, pixels: pixels, order: order)
            let hasArt = picture != nil
            ZStack {
                brand.fill
                // Always there, so the layers it draws with -- and the drift
                // they are part way through -- live as long as the card.
                StreamingPosterArt(picture: picture, motion: motion, span: Self.span, fade: Self.fade)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                if hasArt {
                    // The service's colour rises from the foot of the card
                    // so its mark always sits on its own ground.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.05), location: 0),
                        .init(color: brand.fill.opacity(0), location: 0.34),
                        .init(color: brand.fill.opacity(0.82), location: 0.66),
                        .init(color: brand.fill, location: 0.88)
                    ], startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
                }
                mark(brand, in: proxy.size, hasArt: hasArt)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: ReelKey(urls: urls, pixels: pixels, rotates: motion == .running)) {
                await run(urls, pixels: pixels, rotates: motion == .running)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(service.name)
    }

    @ViewBuilder
    private func mark(_ brand: Brand, in size: CGSize, hasArt: Bool) -> some View {
        Group {
            if UIImage(named: service.logoAsset) != nil {
                logo(brand.ink)
                    .scaledToFit()
                    .frame(maxWidth: size.width * (hasArt ? 0.62 : 0.7),
                           maxHeight: size.height * (hasArt ? 0.17 : 0.24))
            } else {
                // A mark not yet in the catalog: its name, set plainly.
                Text(service.name)
                    .font(.inter(size.width * 0.12, .heavy))
                    .foregroundStyle(brand.ink == .black ? Color.black : Color.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, size.width * 0.1)
            }
        }
        // Centred on the flat card; settled into the foot once there is art.
        .padding(.bottom, hasArt ? size.height * 0.1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasArt ? .bottom : .center)
    }

    private struct ReelKey: Equatable {
        let urls: [URL]
        let pixels: Int
        let rotates: Bool
    }

    /// Puts a picture up as soon as there is one, then, while the poster
    /// moves, changes it on the clock's beat.
    private func run(_ urls: [URL], pixels: Int, rotates: Bool) async {
        guard pixels > 0, !urls.isEmpty else { return }
        let schedule = StreamingPosterSchedule(order: order)
        // The whole reel is fetched now, so each change finds its picture made.
        for url in urls { LineupArt.prefetch(url, pixels: pixels) }

        if loaded == nil {
            if let opening = StreamingPosterSchedule.opening(urls, pixels: pixels, order: order) {
                // Already drawn from the cache; this only keeps it.
                loaded = opening
            } else {
                let preferred = schedule.index(at: CACurrentMediaTime(), count: urls.count)
                guard let first = await StreamingPosterSchedule.firstLoading(urls, from: preferred, pixels: pixels),
                      !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.6)) {
                    loaded = first.began(schedule.began(at: CACurrentMediaTime()))
                }
            }
        }

        // One title only drifts to and fro; it has nothing to change to,
        // unless the reel has moved on from the one on show.
        guard rotates, urls.count > 1 || loaded.map({ !urls.contains($0.url) }) == true else { return }
        let anchor = CACurrentMediaTime()
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            let tick = schedule.nextTick(after: now, anchor: anchor)
            try? await Task.sleep(for: .seconds(max(0, tick - now)))
            if Task.isCancelled { return }
            let target = schedule.target(at: tick, count: urls.count, after: loaded?.index)
            guard let next = StreamingPosterSchedule.nextReady(urls, from: target, pixels: pixels,
                                                               excluding: loaded?.url) else {
                // Nothing else made yet -- evicted, or still on its way. The
                // one on show keeps drifting, and the rest are asked for again.
                for url in urls { LineupArt.prefetch(url, pixels: pixels) }
                continue
            }
            withAnimation(.easeInOut(duration: Self.fade)) {
                loaded = next.began(schedule.began(at: tick))
            }
        }
    }

    /// Wide art fills the card's height and runs well past its sides, so it
    /// is made at that width. Capped at one and a half times the card's
    /// points: the picture is always moving and under the service's colour,
    /// and a row of them must not crowd the rest of the Library's art out of
    /// the cache.
    private static func pixels(for size: CGSize, scale: CGFloat) -> Int {
        // Before the card is laid out there is nothing to size the art to.
        guard size.width >= 1, size.height >= 1 else { return 0 }
        let points = max(size.width, size.height * 16 / 9) * StreamingPosterDrift.zoom
        let raw = points * min(max(scale, 1), 1.5)
        // In steps, so a card a point wider or narrower finds the same one.
        return max(128, Int((raw / 64).rounded(.up)) * 64)
    }
}

/// When a service's poster changes, and to what.
///
/// On the phone the beat is the device's own clock, the same for every
/// poster, each service set a quarter of an interval after the one before:
/// which title is up, and since when, is a function of the time alone. On
/// the television a poster's turn starts when it takes focus and goes round
/// its reel in order, since only that one is moving.
@MainActor
struct StreamingPosterSchedule {
    let offset: Double

    init(order: Int) {
        offset = Double(order % 4) * StreamingServicePoster.interval / 4
    }

    private var interval: Double { StreamingServicePoster.interval }

    /// The beat a moment falls in.
    func slot(at time: CFTimeInterval) -> Int {
        Int(((time - offset) / interval).rounded(.down))
    }

    /// When the title up at a moment came up.
    func began(at time: CFTimeInterval) -> CFTimeInterval? {
        #if os(tvOS)
        nil
        #else
        Double(slot(at: time)) * interval + offset
        #endif
    }

    /// The title the clock puts up at a moment.
    func index(at time: CFTimeInterval, count: Int) -> Int {
        #if os(tvOS)
        0
        #else
        guard count > 0 else { return 0 }
        return ((slot(at: time) % count) + count) % count
        #endif
    }

    func nextTick(after now: CFTimeInterval, anchor: CFTimeInterval) -> CFTimeInterval {
        #if os(tvOS)
        let beats = ((now - anchor) / interval).rounded(.down) + 1
        return anchor + beats * interval
        #else
        return Double(slot(at: now) + 1) * interval + offset
        #endif
    }

    /// The title a beat changes to.
    func target(at tick: CFTimeInterval, count: Int, after current: Int?) -> Int {
        #if os(tvOS)
        ((current ?? -1) + 1) % max(count, 1)
        #else
        // A hair past the beat, so it lands in the beat it starts.
        index(at: tick + 0.001, count: count)
        #endif
    }

    /// What a poster can draw this instant: the title the clock has up, or
    /// failing that the next one already made.
    static func opening(_ urls: [URL], pixels: Int, order: Int) -> StreamingPosterPicture? {
        guard pixels > 0 else { return nil }
        let schedule = StreamingPosterSchedule(order: order)
        let now = CACurrentMediaTime()
        return nextReady(urls, from: schedule.index(at: now, count: urls.count), pixels: pixels, excluding: nil)?
            .began(schedule.began(at: now))
    }

    /// The first picture from `start` on round the reel that is already made.
    static func nextReady(_ urls: [URL], from start: Int, pixels: Int, excluding: URL?) -> StreamingPosterPicture? {
        for step in 0..<urls.count {
            let index = (start + step) % urls.count
            guard urls[index] != excluding, let image = LineupArt.ready(urls[index], pixels: pixels) else { continue }
            return StreamingPosterPicture(url: urls[index], image: image, index: index, began: nil)
        }
        return nil
    }

    /// The first picture from `start` on round the reel that loads.
    static func firstLoading(_ urls: [URL], from start: Int, pixels: Int) async -> StreamingPosterPicture? {
        for step in 0..<urls.count {
            let index = (start + step) % urls.count
            if let image = await LineupArt.load(urls[index], pixels: pixels) {
                return StreamingPosterPicture(url: urls[index], image: image, index: index, began: nil)
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }
}

/// The pictures a service's poster runs through: the art of the titles it
/// has on that the viewer can play, its most popular first. Worked out once
/// for each change of the row, rather than on every redraw.
@MainActor
private final class StreamingPosterReel {
    static let length = 5

    private var key = ""
    private var held: [URL] = []

    func urls(for service: StreamingService, in media: MediaLibrary) -> [URL] {
        let key = service.id + "|" + media.streamingMemoKey
        if key == self.key { return held }
        let titles = media.streamingTitles(for: service)
        let ranked = StreamingSort.popular.sorted(titles.movies + titles.shows)
        var seen = Set<URL>()
        var urls: [URL] = []
        for title in ranked {
            // A title's wide art first, which has room to travel and carries
            // no lettering of its own to crowd the mark; its poster where it
            // has none.
            guard let url = media.backdropURL(for: title.item) ?? media.imageURL(for: title.item),
                  seen.insert(url).inserted else { continue }
            urls.append(url)
            if urls.count == Self.length { break }
        }
        self.key = key
        held = urls
        return urls
    }
}

// MARK: - One service

/// A presentation owned by the service page, independent of the Library's
/// value path and of the movie/show grids that refresh underneath it.
@Observable
final class StreamingServiceNavigation {
    var item: MediaItem?
    func select(_ item: MediaItem) { self.item = item }
}

/// What one service has on that the viewer can play: its films or its shows,
/// one at a time, in the order the viewer chooses. Each title is the same
/// card, and opens the same page, as anywhere else in the Library.
struct StreamingServiceScreen: View {
    @Environment(MediaLibrary.self) private var media
    let service: StreamingService

    @State private var kind: StreamingTitle.Kind = .movie
    @State private var order = StreamingOrderMemo()
    @AppStorage("Lineup.streamingSort.movie") private var movieSort: StreamingSort = .popular
    @AppStorage("Lineup.streamingSort.show") private var showSort: StreamingSort = .popular
    @State private var choosingSort = false
    // The service owns only its selected title. Registering another value
    // destination for MediaItem here shadows the Library's service route and
    // can rebuild the current destination instead of pushing the title.
    @State private var navigation: StreamingServiceNavigation
    private let catalog: StreamingServiceTitles?

    init(service: StreamingService, navigation: StreamingServiceNavigation? = nil, catalog: StreamingServiceTitles? = nil) {
        self.service = service; self.catalog = catalog
        _navigation = State(initialValue: navigation ?? StreamingServiceNavigation())
    }

    private var titles: StreamingServiceTitles { catalog ?? media.streamingTitles(for: service) }

    private var sort: StreamingSort { kind == .movie ? movieSort : showSort }

    private var sortBinding: Binding<StreamingSort> {
        Binding(get: { sort }, set: { value in
            if kind == .movie { movieSort = value } else { showSort = value }
        })
    }

    /// The titles in the chosen order, sorted once per change of order or
    /// of titles rather than on every redraw.
    private var shown: [MediaItem] {
        let key = "\(service.id)|\(kind.rawValue)|\(sort.rawValue)|\(media.streamingMemoKey)"
        if order.key != key {
            order.key = key
            order.items = sort.sorted(titles.titles(kind)).map(\.item)
        }
        return order.items
    }

    var body: some View {
        Group {
            if titles.isEmpty {
                LineupUnavailableView("Nothing to Play Yet", systemImage: "play.slash",
                    description: Text("None of what \(service.name) has on right now is on your servers or your IPTV provider."))
                    .mediaFocusAnchor()
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        .onAppear {
            // A service with only shows opens on its shows.
            if titles.movies.isEmpty, !titles.shows.isEmpty { kind = .show }
        }
        .navigationDestination(item: $navigation.item) { item in MediaBrowseDestination(item: item) }
        #if os(tvOS)
        .tvChoices("Sort \(kind == .movie ? "Movies" : "TV Shows")", symbol: "arrow.up.arrow.down",
                   isPresented: $choosingSort) {
            StreamingSort.allCases.map { option in
                TVChoice(option.label, symbol: option.symbol, id: option.id, isSelected: option == sort) {
                    sortBinding.wrappedValue = option
                }
            }
        }
        #else
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Image(service.logoAsset).resizable().scaledToFit()
                    .frame(maxWidth: 140, maxHeight: 22)
                    .accessibilityLabel(service.name)
            }
        }
        .lineupChoices("Sort \(kind == .movie ? "Movies" : "TV Shows")", symbol: "arrow.up.arrow.down",
                       isPresented: $choosingSort) {
            StreamingSort.allCases.map { option in
                MobileMenuItem(option.label, symbol: option.symbol, id: option.id, isSelected: option == sort) {
                    sortBinding.wrappedValue = option
                }
            }
        }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                header
                controls
                LazyVGrid(columns: Metrics.columns, spacing: Metrics.gridSpacing) {
                    ForEach(shown, id: \.libraryKey) { item in
                        cell(item)
                    }
                }
                .lineupFocusRegion()
                // A new order starts from the top, rather than leaving the
                // grid reshuffled under where the viewer was.
                .id("\(kind.rawValue)|\(sort.rawValue)")
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.top, Metrics.topInset)
            .padding(.bottom, 44)
        }
        .lineupFocusRegion()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.headerGap) {
            #if os(tvOS)
            Image(service.logoAsset).resizable().scaledToFit()
                .frame(maxWidth: 360, maxHeight: 76, alignment: .leading)
                .accessibilityLabel(service.name)
            #endif
            Text(summary)
                .font(.inter(Metrics.summarySize, .medium))
                .foregroundStyle(LineupStyle.secondary)
        }
    }

    /// "42 movies · 18 shows · Updated today", and only what plays.
    private var summary: String {
        var parts: [String] = []
        let movies = titles.movies.count, shows = titles.shows.count
        if movies > 0 { parts.append(movies == 1 ? "1 movie" : "\(movies) movies") }
        if shows > 0 { parts.append(shows == 1 ? "1 show" : "\(shows) shows") }
        if let updated = media.streamingUpdatedAt {
            let calendar = Calendar.current
            if calendar.isDateInToday(updated) { parts.append("Updated today") }
            else if calendar.isDateInYesterday(updated) { parts.append("Updated yesterday") }
            else { parts.append("Updated " + updated.formatted(.dateTime.month(.abbreviated).day())) }
        }
        return parts.joined(separator: " · ")
    }

    /// Movies or TV Shows on the left, the order on the right.
    private var controls: some View {
        HStack(spacing: Metrics.chipGap) {
            kindChip(.movie, title: "Movies", count: titles.movies.count)
            kindChip(.show, title: "TV Shows", count: titles.shows.count)
            Spacer(minLength: 8)
            sortControl
        }
        .lineupFocusRegion()
    }

    @ViewBuilder
    private func kindChip(_ value: StreamingTitle.Kind, title: String, count: Int) -> some View {
        let chip = StreamingChip(title: title, count: count, active: kind == value)
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { kind = value }) { chip }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
        #else
        Button { withAnimation(.easeOut(duration: 0.18)) { kind = value } } label: { chip }
            .lineupFlatButton()
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
        #endif
    }

    @ViewBuilder
    private var sortControl: some View {
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { choosingSort = true }) {
            StreamingSortLabel(sort: sort)
        }
        #else
        // The app's own sheet of choices rather than the system's menu,
        // which draws in its own glass and type.
        Button { choosingSort = true } label: {
            StreamingSortLabel(sort: sort)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(sort.label)")
        #endif
    }

    @ViewBuilder
    private func cell(_ item: MediaItem) -> some View {
        #if os(tvOS)
        TVSelectable(drawsFocusChrome: false, action: { navigation.select(item) }) {
            MediaItemCard(item: item, shape: .poster)
        }
        #else
        Button { navigation.select(item) } label: { MediaItemCard(item: item, shape: .poster) }
            .lineupFlatButton()
            .accessibilityIdentifier("lineup.streaming.title.\(item.libraryKey)")
        #endif
    }
}

// MARK: - Every service

/// The whole row, from its See All: every service with something to play.
struct StreamingServicesScreen: View {
    @Environment(MediaLibrary.self) private var media
    @State private var pushed: MediaItem?

    private var services: [MediaItem] { media.streamingShelf?.items ?? [] }

    var body: some View {
        Group {
            if services.isEmpty {
                LineupUnavailableView("Nothing to Play Yet", systemImage: "play.slash",
                    description: Text("None of what the streaming services have on right now is on your servers or your IPTV provider."))
                    .mediaFocusAnchor()
            } else {
                ScrollView {
                    LazyVGrid(columns: Metrics.columns, spacing: Metrics.gridSpacing) {
                        ForEach(services, id: \.libraryKey) { item in
                            #if os(tvOS)
                            TVSelectable(drawsFocusChrome: false, action: { pushed = item }) {
                                MediaItemCard(item: item, shape: .poster)
                            }
                            #else
                            Button { pushed = item } label: { MediaItemCard(item: item, shape: .poster) }
                                .lineupFlatButton()
                            #endif
                        }
                    }
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, Metrics.topInset)
                    .lineupFocusRegion()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        #if !os(tvOS)
        .navigationTitle(StreamingService.rowTitle)
        #endif
    }
}

// MARK: - Pieces

/// A service screen's last ordering, kept across redraws.
private final class StreamingOrderMemo {
    var key = ""
    var items: [MediaItem] = []
}

/// Movies or TV Shows, and how many of each: the chosen one is filled.
private struct StreamingChip: View {
    let title: String
    let count: Int
    let active: Bool
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var focused
    #endif

    var body: some View {
        HStack(spacing: Metrics.chipCountGap) {
            Text(title).font(.inter(Metrics.chipSize, .bold))
            Text("\(count)").font(.interDigits(Metrics.chipSize, .bold)).opacity(0.55)
        }
        .padding(.horizontal, Metrics.chipPadding)
        .frame(height: Metrics.chipHeight)
        // Filled with the accent when chosen, its outline otherwise, on the
        // phone and the television alike.
        .foregroundStyle(active ? LineupStyle.onHighlight : LineupStyle.highlight)
        .background(Capsule().fill(active ? LineupStyle.highlight : Color.clear))
        .overlay(Capsule().strokeBorder(active ? Color.clear : LineupStyle.highlight, lineWidth: 1.5))
        #if os(tvOS)
        .lineupFocusLayer(focused, in: Capsule())
        #endif
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.18), value: active)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// The order in use, and that it can be changed.
private struct StreamingSortLabel: View {
    let sort: StreamingSort
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var focused
    #endif

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: Metrics.chipSize - 3, weight: .bold, design: .rounded))
                .foregroundStyle(LineupStyle.secondary)
            Text(sort.label).font(.inter(Metrics.chipSize, .semibold)).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: Metrics.chipSize - 5, weight: .bold, design: .rounded))
                .foregroundStyle(LineupStyle.secondary)
        }
        .foregroundStyle(LineupStyle.text)
        .padding(.horizontal, Metrics.chipPadding)
        .frame(height: Metrics.chipHeight)
        .background(Capsule().fill(LineupStyle.surface))
        .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 1))
        #if os(tvOS)
        .lineupFocusLayer(focused, in: Capsule())
        #endif
        .contentShape(Capsule())
    }
}

private enum Metrics {
    #if os(tvOS)
    static let inset: CGFloat = 70
    static let topInset: CGFloat = 30
    static let sectionGap: CGFloat = 30
    static let headerGap: CGFloat = 16
    static let summarySize: CGFloat = 22
    static let chipSize: CGFloat = 22
    static let chipHeight: CGFloat = 54
    static let chipPadding: CGFloat = 24
    static let chipGap: CGFloat = 16
    static let chipCountGap: CGFloat = 10
    static let gridSpacing: CGFloat = 30
    static let columns = [GridItem(.adaptive(minimum: 250, maximum: 310), spacing: 24)]
    #else
    static let inset: CGFloat = 16
    static let topInset: CGFloat = 8
    static let sectionGap: CGFloat = 16
    static let headerGap: CGFloat = 6
    static let summarySize: CGFloat = 13
    static let chipSize: CGFloat = 14
    static let chipHeight: CGFloat = 34
    static let chipPadding: CGFloat = 14
    static let chipGap: CGFloat = 8
    static let chipCountGap: CGFloat = 6
    static let gridSpacing: CGFloat = 20
    static let columns = [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 14)]
    #endif
}
