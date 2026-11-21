import SwiftUI

/// Keyword-based visual styling for IPTV guide categories so sports, news,
/// movies, locals, kids, and 4K categories scan at a glance instead of looking
/// like identical folders.
enum MobileGuideCategoryStyle {
    struct Appearance {
        let symbol: String
        let tint: Color
    }

    static func symbol(for categoryName: String) -> String {
        appearance(for: categoryName).symbol
    }

    static func appearance(for categoryName: String) -> Appearance {
        let lower = categoryName.lowercased()
        if matchesAny(lower, ["sport", "nfl", "nba", "mlb", "nhl", "ncaa", "soccer", "futbol", "football",
                              "ufc", "mma", "boxing", "ppv", "espn", "f1", "racing", "nascar", "golf",
                              "tennis", "cricket", "rugby", "bally", "fan duel", "fanduel", "rsn"]) {
            return Appearance(symbol: "sportscourt.fill", tint: Color(red: 0.16, green: 0.78, blue: 0.45))
        }
        if matchesAny(lower, ["4k", "uhd", "hevc", "60fps", "vip", "raw", "ultra"]) {
            return Appearance(symbol: "sparkles.tv.fill", tint: Color(red: 0.98, green: 0.75, blue: 0.22))
        }
        if matchesAny(lower, ["movie", "cinema", "film", "hbo", "showtime", "starz", "cinemax", "box office"]) {
            return Appearance(symbol: "film.fill", tint: Color(red: 0.95, green: 0.34, blue: 0.38))
        }
        if matchesAny(lower, ["news", "weather", "business", "cnn", "fox news", "msnbc", "cnbc", "bbc"]) {
            return Appearance(symbol: "newspaper.fill", tint: Color(red: 0.28, green: 0.64, blue: 0.98))
        }
        if matchesAny(lower, ["local", "broadcast", "abc", "cbs", "nbc", "fox", "pbs", "cw ", "regional"]) {
            return Appearance(symbol: "antenna.radiowaves.left.and.right", tint: Color(red: 0.20, green: 0.76, blue: 0.80))
        }
        if matchesAny(lower, ["kid", "family", "cartoon", "disney", "nick", "anime", "junior"]) {
            return Appearance(symbol: "sparkles", tint: Color(red: 1.0, green: 0.66, blue: 0.22))
        }
        if matchesAny(lower, ["24/7", "24-7", "24x7", "always on"]) {
            return Appearance(symbol: "play.circle.fill", tint: Color(red: 0.98, green: 0.50, blue: 0.22))
        }
        if matchesAny(lower, ["music", "concert", "radio", "mtv", "vevo"]) {
            return Appearance(symbol: "music.note", tint: Color(red: 0.94, green: 0.36, blue: 0.68))
        }
        if matchesAny(lower, ["docu", "nature", "science", "history", "discovery", "nat geo", "animal"]) {
            return Appearance(symbol: "globe.americas.fill", tint: Color(red: 0.24, green: 0.74, blue: 0.92))
        }
        if matchesAny(lower, ["entertain", "drama", "comedy", "series", "show", "lifestyle", "reality"]) {
            return Appearance(symbol: "tv.fill", tint: Color(red: 0.54, green: 0.46, blue: 0.96))
        }
        return Appearance(symbol: "rectangle.stack.fill", tint: Color(red: 0.58, green: 0.62, blue: 0.72))
    }

    private static func matchesAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

/// The TV Guide tab's first page: what there is to watch, by category, styled
/// to match the rest of Lineup with quick-launch cards, channel counts, smart
/// category icons, and instant top-bar search/layout switching.
struct MobileGuideCategoryList: View {
    let categories: [XtreamCategory]
    let hasFavorites: Bool
    let hasRecents: Bool
    var favoritesCount: Int = 0
    var recentsCount: Int = 0
    var totalChannelsCount: Int = 0
    var categoryCounts: [String: Int] = [:]
    /// The category saved as the one to open on, by its display ID.
    let defaultCategoryID: String?
    let allowsDefault: (XtreamCategory) -> Bool
    let open: (MobileGuideFilter) -> Void
    let setDefault: (XtreamCategory, Bool) -> Void
    let hide: (XtreamCategory) -> Void
    let manageCategories: () -> Void
    /// What the TV Guide's options menu held, now also reachable from the top bar.
    let viewModeTitle: String
    var viewModeSymbol: String = "rectangle.grid.1x2"
    var showMasthead: Bool = true
    let isRefreshing: Bool
    let search: () -> Void
    let changeViewMode: () -> Void
    let refresh: () -> Void
    /// The providers whose channels are combined, in their order, each with
    /// its categories. With more than one, each is a section of its own that
    /// opens and closes, and a category goes by its own name, not
    /// "Provider · Name".
    var providers: [Provider] = []

    struct Provider: Identifiable {
        let id: UUID
        let name: String
        let categories: [XtreamCategory]
        var hasFavorites = false
        var hasRecents = false
        var favoritesCount = 0
        var recentsCount = 0
        var channelCount = 0
    }

    /// Providers closed by the viewer, kept between visits.
    @AppStorage("Lineup.guide.closedProviders.v1") private var closedProviders = ""
    private var closed: Set<String> { Set(closedProviders.split(separator: ",").map(String.init)) }

    private static let cardFill = Color(red: 0.088, green: 0.092, blue: 0.112)
    private static let cardBorder = Color.white.opacity(0.075)
    private static let quickColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if showMasthead {
                    masthead
                }

                quickAccessGrid

                if providers.count > 1 {
                    ForEach(providers) { provider in
                        providerSection(provider)
                    }
                    footerHint
                } else {
                    singleProviderCategoriesSection
                }

                guideToolsSection
            }
            .padding(.horizontal, LineupPanelStyle.margin)
            .padding(.top, showMasthead ? 4 : 10)
            .padding(.bottom, 28)
        }
        .background(Color.black.ignoresSafeArea())
        .refreshable { refresh() }
    }

    // MARK: - Masthead

    private var masthead: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                Image("LineupBrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("TV GUIDE")
                        .font(.inter(20, .black)).tracking(-0.5)
                        .foregroundStyle(LineupStyle.text.opacity(0.95))
                    Text(mastheadSubtitle)
                        .font(.inter(10, .bold)).tracking(0.75)
                        .foregroundStyle(LineupStyle.secondary.opacity(0.76))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 6)

            HStack(spacing: 8) {
                Button(action: changeViewMode) {
                    Image(systemName: viewModeSymbol)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(LineupStyle.text.opacity(0.9))
                        .frame(width: 36, height: 36)
                        .background(Self.cardFill, in: Circle())
                        .overlay(Circle().strokeBorder(Self.cardBorder, lineWidth: 1))
                }
                .buttonStyle(MobileCardButtonStyle())
                .accessibilityLabel("Layout: \(viewModeTitle)")
                .accessibilityHint("Switches between the TV Guide grid and a list")

                Button(action: search) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(LineupStyle.text.opacity(0.9))
                        .frame(width: 36, height: 36)
                        .background(Self.cardFill, in: Circle())
                        .overlay(Circle().strokeBorder(Self.cardBorder, lineWidth: 1))
                }
                .buttonStyle(MobileCardButtonStyle())
                .accessibilityLabel("Search channels")

                Button(action: refresh) {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(LineupStyle.text.opacity(0.9))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(Self.cardFill, in: Circle())
                    .overlay(Circle().strokeBorder(Self.cardBorder, lineWidth: 1))
                }
                .buttonStyle(MobileCardButtonStyle())
                .disabled(isRefreshing)
                .accessibilityLabel(isRefreshing ? "Refreshing guide" : "Refresh guide")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var mastheadSubtitle: String {
        let channelsText = totalChannelsCount > 0
            ? "\(totalChannelsCount.formatted()) CHANNELS"
            : "\(categories.count) CATEGORIES"
        if providers.count > 1 {
            return "\(providers.count) PROVIDERS · \(channelsText)"
        }
        return channelsText
    }

    // MARK: - Quick Access Bento

    private var quickAccessGrid: some View {
        LazyVGrid(columns: Self.quickColumns, spacing: 10) {
            quickCard(
                title: "Favorites",
                subtitle: hasFavorites ? countLabel(favoritesCount, singular: "channel") : "None yet",
                symbol: "star.fill",
                tint: Color(red: 1.0, green: 0.76, blue: 0.18),
                action: { open(.favorites) }
            )
            quickCard(
                title: "All Channels",
                subtitle: totalChannelsCount > 0 ? countLabel(totalChannelsCount, singular: "channel") : "Browse all",
                symbol: "tv.fill",
                tint: LineupStyle.highlight,
                action: { open(.all) }
            )
            if hasRecents {
                quickCard(
                    title: "Recently Watched",
                    subtitle: countLabel(recentsCount, singular: "channel"),
                    symbol: "clock.arrow.circlepath",
                    tint: Color(red: 0.36, green: 0.62, blue: 1.0),
                    action: { open(.recents) }
                )
            } else {
                quickCard(
                    title: "Manage Categories",
                    subtitle: "\(categories.count) visible",
                    symbol: "slider.horizontal.3",
                    tint: Color(red: 0.56, green: 0.54, blue: 0.94),
                    action: manageCategories
                )
            }
            quickCard(
                title: "Search Channels",
                subtitle: "Jump to any channel",
                symbol: "magnifyingglass",
                tint: Color(red: 0.22, green: 0.78, blue: 0.74),
                action: search
            )
        }
    }

    private func quickCard(title: String, subtitle: String, symbol: String, tint: Color,
                           action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.20), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.32))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.inter(15, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.interDigits(11.5, .medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Self.cardFill)
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.20), tint.opacity(0.04)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay(shape.strokeBorder(tint.opacity(0.24), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(MobileCardButtonStyle())
    }

    // MARK: - Provider & Category Sections

    private func providerSection(_ provider: Provider) -> some View {
        let isOpen = !closed.contains(provider.id.uuidString)
        return VStack(alignment: .leading, spacing: 10) {
            providerHeader(provider, open: isOpen)
            if isOpen {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        providerPill("Favorites", symbol: "star.fill",
                                     tint: Color(red: 1.0, green: 0.76, blue: 0.18),
                                     count: provider.hasFavorites ? provider.favoritesCount : nil) {
                            open(.providerFavorites(provider.id))
                        }
                        if provider.hasRecents {
                            providerPill("Recent", symbol: "clock.arrow.circlepath",
                                         tint: Color(red: 0.36, green: 0.62, blue: 1.0),
                                         count: provider.recentsCount) {
                                open(.providerRecents(provider.id))
                            }
                        }
                        providerPill("All Channels", symbol: "tv.fill",
                                     tint: LineupStyle.highlight,
                                     count: provider.channelCount > 0 ? provider.channelCount : nil) {
                            open(.providerAll(provider.id))
                        }
                    }
                    .padding(.vertical, 1)
                }

                categoryCardGroup(provider.categories) { category in
                    category.sourceCategoryName ?? category.categoryName
                }
            }
        }
    }

    private func providerPill(_ title: String, symbol: String, tint: Color, count: Int?,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.inter(12.5, .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.interDigits(11, .bold))
                        .foregroundStyle(Color.white.opacity(0.54))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Self.cardFill, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.9))
        }
        .buttonStyle(MobileCardButtonStyle())
    }

    private func providerHeader(_ provider: Provider, open: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            var set = closed
            if open { set.insert(provider.id.uuidString) } else { set.remove(provider.id.uuidString) }
            withAnimation(.easeInOut(duration: 0.2)) {
                closedProviders = set.sorted().joined(separator: ",")
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LineupStyle.highlight)
                    .frame(width: 28, height: 28)
                    .background(LineupStyle.highlight.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name)
                        .font(.inter(14, .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(providerDetail(provider))
                        .font(.interDigits(11, .medium))
                        .foregroundStyle(Color.white.opacity(0.54))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(0.05), in: shape)
            .overlay(shape.strokeBorder(Self.cardBorder, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(MobileCardButtonStyle())
        .accessibilityLabel("\(provider.name), \(provider.categories.count) categories")
        .accessibilityValue(open ? "Open" : "Closed")
        .accessibilityHint(open ? "Closes this provider's categories" : "Shows this provider's categories")
    }

    private func providerDetail(_ provider: Provider) -> String {
        let cats = "\(provider.categories.count) \(provider.categories.count == 1 ? "category" : "categories")"
        if provider.channelCount > 0 {
            return "\(cats) · \(provider.channelCount.formatted()) ch"
        }
        return cats
    }

    private var singleProviderCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("CATEGORIES")
                    .font(.inter(12, .heavy)).tracking(0.7)
                    .foregroundStyle(LineupStyle.text.opacity(0.72))
                if !categories.isEmpty {
                    Text("\(categories.count)")
                        .font(.interDigits(11, .bold))
                        .foregroundStyle(LineupStyle.secondary.opacity(0.8))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            if categories.isEmpty {
                Button(action: manageCategories) {
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LineupStyle.secondary)
                        Text("Every category is hidden. Choose which to show.")
                            .font(.inter(.subheadline, .medium))
                            .foregroundStyle(LineupStyle.text.opacity(0.82))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(LineupPanelStyle.listChevron)
                    }
                    .padding(14)
                    .background(Self.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Self.cardBorder, lineWidth: 1))
                }
                .buttonStyle(MobileCardButtonStyle())
            } else {
                categoryCardGroup(categories) { $0.categoryName }
            }

            footerHint
        }
    }

    private func categoryCardGroup(_ items: [XtreamCategory],
                                   nameFor: @escaping (XtreamCategory) -> String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, category in
                categoryRow(category, name: nameFor(category))
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.065))
                        .frame(height: 1)
                        .padding(.leading, 56)
                }
            }
        }
        .background(Self.cardFill, in: shape)
        .overlay(shape.strokeBorder(Self.cardBorder, lineWidth: 1))
        .clipShape(shape)
    }

    private func categoryRow(_ category: XtreamCategory, name: String) -> some View {
        let isDefault = defaultCategoryID == category.id
        let style = MobileGuideCategoryStyle.appearance(for: name)
        let count = categoryCounts[category.id]
        return HStack(spacing: 12) {
            Image(systemName: style.symbol)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(style.tint)
                .frame(width: 32, height: 32)
                .background(style.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.inter(15, .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if isDefault {
                    Text("OPENS FIRST")
                        .font(.inter(9, .heavy)).tracking(0.5)
                        .foregroundStyle(LineupStyle.highlight)
                }
            }

            Spacer(minLength: 8)

            if let count, count > 0 {
                Text(count.formatted())
                    .font(.interDigits(12, .semibold))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.28))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .contentShape(Rectangle())
        .lineupHoldMenu(name, symbol: style.symbol, tint: style.tint, press: .dim, items: {
            var items: [MobileMenuItem] = []
            if allowsDefault(category) {
                items.append(MobileMenuItem(isDefault ? "Don't Open on This" : "Open TV Guide on This",
                                            symbol: isDefault ? "house" : "house.fill") {
                    setDefault(category, !isDefault)
                })
            }
            items.append(MobileMenuItem("Hide Category", symbol: "eye.slash") { hide(category) })
            items.append(MobileMenuItem("Manage Categories", symbol: "list.bullet") { manageCategories() })
            return items
        }) {
            open(.category(category.id))
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the TV Guide on this category")
    }

    // MARK: - Guide Tools Footer

    private var guideToolsSection: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 9) {
            Text("GUIDE OPTIONS")
                .font(.inter(12, .heavy)).tracking(0.7)
                .foregroundStyle(LineupStyle.text.opacity(0.72))
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                toolRow("Layout", symbol: viewModeSymbol, tint: Color(red: 0.42, green: 0.66, blue: 1.0),
                        detail: viewModeTitle, action: changeViewMode)
                    .accessibilityHint("Switches between the TV Guide grid and a list")
                Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1).padding(.leading, 56)
                toolRow("Manage Categories", symbol: "eye.slash", tint: Color(red: 0.72, green: 0.54, blue: 0.98),
                        detail: nil, action: manageCategories)
                Rectangle().fill(Color.white.opacity(0.065)).frame(height: 1).padding(.leading, 56)
                Button(action: refresh) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.24, green: 0.78, blue: 0.58))
                            .frame(width: 32, height: 32)
                            .background(Color(red: 0.24, green: 0.78, blue: 0.58).opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(isRefreshing ? "Refreshing Guide…" : "Refresh Guide")
                            .font(.inter(15, .semibold))
                            .foregroundStyle(Color.white.opacity(0.94))
                        Spacer(minLength: 8)
                        if isRefreshing { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }
            .background(Self.cardFill, in: shape)
            .overlay(shape.strokeBorder(Self.cardBorder, lineWidth: 1))
            .clipShape(shape)
        }
    }

    private func toolRow(_ title: String, symbol: String, tint: Color, detail: String?,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.inter(15, .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.inter(13, .semibold))
                        .foregroundStyle(Color.white.opacity(0.54))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footerHint: some View {
        Text("Touch and hold any category to open TV Guide on it by default, or to hide it.")
            .font(.inter(12, .medium))
            .foregroundStyle(LineupStyle.secondary.opacity(0.68))
            .padding(.horizontal, 6)
    }

    private func countLabel(_ count: Int, singular: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : singular + "s")"
    }
}
