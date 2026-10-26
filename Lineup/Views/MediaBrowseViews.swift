import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// A run of cards in a grid with a heading of its own: one server's search
/// results. A section with no title is just the grid.
struct MediaGridSection: Identifiable {
    let id: String
    let title: String?
    /// The logo of the server the section is named for.
    var brand: MediaServerBrand? = nil
    let items: [MediaItem]
}

struct MediaGridScreen: View {
    @Environment(MediaLibrary.self) private var media
    let title: String
    let sections: [MediaGridSection]
    // tvOS pushes by hand because its cards are not NavigationLinks any more.
    @State private var pushed: MediaItem?
    @State private var choosingShelf = false

    init(title: String, items: [MediaItem]) {
        self.title = title
        sections = [MediaGridSection(id: "all", title: nil, items: items)]
    }

    init(title: String, sections: [MediaGridSection]) {
        self.title = title
        self.sections = sections
    }

    private var items: [MediaItem] { sections.flatMap(\.items) }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 16) {
                        if let heading = section.title {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                if let brand = section.brand {
                                    MediaServerLogo(brand: brand)
                                        .frame(width: sectionLogoSize, height: sectionLogoSize)
                                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                                }
                                Text(heading).font(headingFont)
                                Text(section.items.count == 1 ? "1 result" : "\(section.items.count) results")
                                    .font(.inter(13, .semibold))
                                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                            }
                        }
                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(section.items, id: \.libraryKey) { item in
                                cell(item)
                            }
                        }
                        // Down from a section's last row reaches the next one.
                        .lineupFocusRegion()
                    }
                }
            }
            .padding(.horizontal, horizontalPadding).padding(.vertical, 28)
        }
        .lineupFocusRegion()
    }

    @ViewBuilder
    private func cell(_ item: MediaItem) -> some View {
        if item.opensPage {
            #if os(tvOS)
            TVSelectable(drawsFocusChrome: false, action: { pushed = item }) {
                MediaItemCard(item: item, shape: shape)
            }
            .tvHoldMenu(item.name, symbol: "film") { media.tvCardChoices(for: item) }
            #else
            MediaItemCard(item: item, shape: shape)
                .lineupHoldMenu(item.name, symbol: "film", items: { media.cardMenuItems(for: item) }) { pushed = item }
            #endif
        } else {
            MediaPlayableCard(item: item, shape: shape)
        }
    }

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        grid.navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
            .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        #else
        grid.navigationTitle(title)
            .background(LineupPresentationStyle.ground.ignoresSafeArea())
            .foregroundStyle(LineupPresentationStyle.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LineupPresentationStyle.ground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .lineupPresentation()
            .mobileExpandNavigationOnAppear()
            .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
            .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        #endif
    }

    private var shape: MediaArtShape { .forItems(items) }

    private var columns: [GridItem] {
        #if os(tvOS)
        shape == .poster
            ? [GridItem(.adaptive(minimum: 250, maximum: 310), spacing: 24)]
            : [GridItem(.adaptive(minimum: 360, maximum: 460), spacing: 24)]
        #else
        shape == .poster
            ? [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 14)]
            : [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 14)]
        #endif
    }
    private var gridSpacing: CGFloat {
        #if os(tvOS)
        30
        #else
        20
        #endif
    }
    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        44
        #else
        28
        #endif
    }
    private var headingFont: Font {
        #if os(tvOS)
        .inter(24, .semibold)
        #else
        .inter(.title3, .bold)
        #endif
    }
    /// A server's logo beside its section's heading, the heading's height.
    private var sectionLogoSize: CGFloat {
        #if os(tvOS)
        24
        #else
        18
        #endif
    }
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        70
        #else
        LineupPanelStyle.inset
        #endif
    }
}

/// A series or a film opens to its own page; anything else is still a grid of
/// what is inside it. All of it is registered under one item type, so the
/// choice has to be made here rather than at the link.
struct MediaBrowseDestination: View {
    let item: MediaItem

    var body: some View {
        // Anything that plays has a page when it is opened on purpose -- a
        // server's "Video" from Continue Watching as much as a "Movie".
        if let service = StreamingService.service(for: item) {
            StreamingServiceScreen(service: service)
        } else if item.id == StreamingService.rowID {
            StreamingServicesScreen()
        } else if LibraryTrendingRow.row(id: item.id) != nil {
            TrendingRowScreen(id: item.id, title: item.name)
        } else if item.hasDetailPage || item.isPlayable {
            MediaDetailScreen(item: item)
        } else {
            MediaFolderScreen(folder: item)
        }
    }
}

/// A trending row's See All: every title it holds, in the chart's order.
private struct TrendingRowScreen: View {
    @Environment(MediaLibrary.self) private var media
    let id: String
    let title: String

    var body: some View {
        let items = media.trendingShelves.first { $0.id == id }?.items ?? []
        if items.isEmpty {
            LineupUnavailableView("Nothing to Play Yet", systemImage: "chart.line.uptrend.xyaxis",
                description: Text("None of what is trending right now is on your servers or your IPTV provider."))
                .mediaFocusAnchor()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LineupStyle.background.ignoresSafeArea())
        } else {
            MediaGridScreen(title: title, items: items)
                .background(LineupStyle.background.ignoresSafeArea())
        }
    }
}

private struct MediaFolderScreen: View {
    @Environment(MediaLibrary.self) private var media
    let folder: MediaItem
    @State private var items: [MediaItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading \(folder.name)…").mediaFocusAnchor()
            } else if let error {
                LineupUnavailableView("Couldn’t Load Library", systemImage: "exclamationmark.triangle",
                    description: Text(error)).mediaFocusAnchor()
            } else if items.isEmpty {
                LineupUnavailableView("Nothing Here", systemImage: "film.stack",
                    description: Text("This library did not return any playable items.")).mediaFocusAnchor()
            } else {
                MediaGridScreen(title: folder.name, items: items)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .task(id: folder.libraryKey) {
            loading = true
            do { items = try await media.items(in: folder); error = nil }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

/// Keep Library artwork clear behind the status bar and its own toolbar
/// controls. The scroll-edge effect is separate from the bar background.
struct ClearLibraryHeader: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        if #available(iOS 26.0, *) {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            content.toolbarBackground(.hidden, for: .navigationBar)
        }
        #endif
    }
}

/// On iPhone the hero art runs to the very top of the screen, under a
/// navigation bar carrying no background of its own.
///
/// tvOS gets neither half. Its tab bar sits along the *top* edge and appears
/// when focus moves up into it, so a screen that ignores the top safe area
/// draws over that bar and takes the focus meant for it -- leaving the Menu
/// button with nowhere to go and the viewer stuck on the page. Every other tvOS
/// screen here ignores `[.horizontal, .bottom]` and leaves the top alone for
/// exactly this reason.
struct FullBleedHeader: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .ignoresSafeArea(edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ClearLibraryHeader())
        #endif
    }
}

/// Which shelves to show, in two groups: the server's own libraries, and the
/// collections -- which on a Nullfin server is where an enabled catalog
/// lands, one collection per catalog.
///
/// Lineup only ever asked `/views` for this list, and that route answers with
/// promoted collections alone. An imported catalog is left unpromoted, so no
/// number of them could put one in front of the viewer. The second
/// group is the part that was missing.
struct MediaShelfPicker: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @State private var adding: Set<String> = []

    private struct Group: Identifiable {
        let id: String
        let title: String
        let detail: String
        /// The logo of the server the group is named for.
        var brand: MediaServerBrand? = nil
        let items: [MediaItem]
    }

    private struct MDBListGroup: Identifiable {
        let section: MDBListCatalogSection
        let items: [MDBListCatalog]
        var id: MDBListCatalogSection { section }
    }

    /// Each server's libraries and catalogs, server by server. With more than
    /// one, every heading says whose they are.
    private var groups: [Group] {
        let several = media.profiles.count > 1
        let servers = media.profiles.flatMap { server -> [Group] in
            let owner = several ? " · " + server.name.uppercased() : ""
            let brand = several ? MediaServerBrand.of(server) : nil
            return [Group(id: server.id.uuidString + "|libraries", title: "LIBRARIES" + owner,
                          detail: several ? "Folders \(server.name) keeps itself" : "Folders this server keeps itself",
                          brand: brand, items: media.availableLibraries(on: server)),
                    Group(id: server.id.uuidString + "|catalogs", title: "IMPORTED CATALOGS" + owner,
                          detail: several ? "Already on \(server.name), ready to shelve" : "Already on your server, ready to shelve",
                          brand: brand, items: media.availableCatalogs(on: server))]
        }
        // The IPTV provider's own categories, films and then shows.
        var provider: [Group] = []
        if let name = media.providerVOD.profile?.name {
            let shelves = media.availableProviderShelves
            provider = [Group(id: "provider|films", title: "MOVIES · " + name.uppercased(),
                              detail: "Film categories from your IPTV provider", items: shelves.films),
                        Group(id: "provider|shows", title: "SERIES · " + name.uppercased(),
                              detail: "Series categories from your IPTV provider", items: shelves.shows)]
        }
        return (servers + provider).filter { !$0.items.isEmpty }
    }

    private var mdbListGroups: [MDBListGroup] {
        MDBListCatalogSection.allCases.compactMap { section in
            let items = media.availableMDBListCatalogs.filter { $0.section == section }
            return items.isEmpty ? nil : MDBListGroup(section: section, items: items)
        }
    }

    private var hasAnything: Bool {
        !media.hiddenBuiltInRows.isEmpty || !groups.isEmpty || !media.addonGroups.isEmpty
            || !media.availableMDBListCatalogs.isEmpty
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ADD A SHELF").modifier(LineupGroupHeading())
                Text("Pick a row for the Library tab")
                    .font(.inter(22, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 18)
            list
        }
        .frame(maxWidth: 1180, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .foregroundStyle(LineupPresentationStyle.text)
        .onExitCommand { dismiss() }
        .task { await loadSources() }
        #else
        NavigationStack {
            list
                .navigationTitle("Add Shelf")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    LineupToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                            .buttonStyle(LineupBarButtonStyle(prominent: true))
                    }
                }
        }
        .task { await loadSources() }
        #endif
    }

    @ViewBuilder
    private var list: some View {
        if !hasAnything {
            LineupUnavailableView("Every Shelf Is Showing", systemImage: "rectangle.stack.badge.plus",
                description: Text(emptyDetail))
                .mediaFocusAnchor()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // The Library's own row, back once it was taken away.
                    if !media.hiddenBuiltInRows.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("BUILT IN").modifier(LineupGroupHeading())
                            Text("Rows Lineup puts together for you").font(.inter(13))
                                .foregroundStyle(LineupPresentationStyle.text.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(media.hiddenBuiltInRows) { row in
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift, fillRadius: 14,
                                         action: { media.setShowsBuiltInRow(row.id, true) }) {
                                MediaShelfRow(title: row.title, detail: row.detail, busy: false)
                            }
                            #else
                            Button { media.setShowsBuiltInRow(row.id, true) } label: {
                                MediaShelfRow(title: row.title, detail: row.detail, busy: false)
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                if let brand = group.brand {
                                    MediaServerLogo(brand: brand).frame(width: 14, height: 14)
                                }
                                Text(group.title).modifier(LineupGroupHeading())
                            }
                            Text(group.detail).font(.inter(13))
                                .foregroundStyle(LineupPresentationStyle.text.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(group.items, id: \.libraryKey) { item in
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift,
                                fillRadius: 14, action: { add(item) }) {
                                MediaShelfRow(title: item.name, detail: countText(item),
                                    busy: adding.contains(item.libraryKey))
                            }
                            #else
                            Button { add(item) } label: {
                                MediaShelfRow(title: item.name, detail: countText(item),
                                    busy: adding.contains(item.libraryKey))
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                    ForEach(mdbListGroups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.section.title).modifier(LineupGroupHeading())
                            Text(group.section.detail + " — playable titles found on "
                                 + (media.profiles.count > 1 ? "your media servers" : "this media server"))
                                .font(.inter(13))
                                .foregroundStyle(LineupPresentationStyle.text.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(group.items) { catalog in
                            let busy = adding.contains(catalog.shelfID)
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift,
                                fillRadius: 14, action: { addMDBList(catalog) }) {
                                MediaShelfRow(title: catalog.name,
                                    detail: catalog.itemCount.map { "\($0) list titles" }, busy: busy)
                            }
                            #else
                            Button { addMDBList(catalog) } label: {
                                MediaShelfRow(title: catalog.name,
                                    detail: catalog.itemCount.map { "\($0) list titles" }, busy: busy)
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                    // Catalogs the server offers that it is not importing yet.
                    // Choosing one switches it on and asks the server to fetch
                    // it, which it then does in its own time.
                    ForEach(media.addonGroups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                if media.serverName(of: group.serverID) != nil,
                                   let brand = media.serverBrand(of: group.serverID) {
                                    MediaServerLogo(brand: brand).frame(width: 14, height: 14)
                                }
                                Text(addonHeading(group))
                                    .modifier(LineupGroupHeading())
                            }
                            // The server re-imports every enabled catalog when
                            // asked, so this is minutes, not seconds. Saying so
                            // is the difference between waiting and giving up.
                            Text(media.importing.isEmpty
                                ? "Not imported yet — choosing one starts the import"
                                : "Importing can take several minutes. You can close this; it keeps going.")
                                .font(.inter(13))
                                .foregroundStyle(LineupPresentationStyle.text.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(group.catalogs) { catalog in
                            let busy = media.isImporting(catalog, in: group)
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift, fillRadius: 14,
                                action: { enable(catalog, in: group) }) {
                                MediaShelfRow(title: catalog.name,
                                    detail: busy ? "Importing… select again to stop waiting" : nil,
                                    busy: busy)
                            }
                            #else
                            Button { enable(catalog, in: group) } label: {
                                MediaShelfRow(title: catalog.name,
                                    detail: busy ? "Importing… tap again to stop waiting" : nil,
                                    busy: busy)
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                }
                .padding(.horizontal, rowPadding).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .lineupFocusRegion()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LineupPresentationStyle.ground.ignoresSafeArea())
            .foregroundStyle(LineupPresentationStyle.text)
        }
    }

    /// The picker stays up: a row leaves the list as its shelf appears behind,
    /// so several can be added without reopening this each time.
    private func add(_ item: MediaItem) {
        guard !adding.contains(item.libraryKey) else { return }
        adding.insert(item.libraryKey)
        Task { @MainActor in
            await media.addShelf(item)
            adding.remove(item.libraryKey)
        }
    }

    private func addMDBList(_ catalog: MDBListCatalog) {
        guard !adding.contains(catalog.shelfID) else { return }
        adding.insert(catalog.shelfID)
        Task { @MainActor in
            await media.addMDBListShelf(catalog)
            adding.remove(catalog.shelfID)
        }
    }

    private func loadSources() async {
        async let addons: Void = media.loadAddonCatalogs()
        async let mdbList: Void = media.loadMDBListIntegration()
        async let provider: Void = media.loadProviderCatalog()
        _ = await (addons, mdbList, provider)
    }

    /// Switching a catalog on is the server's work, not this screen's: it can
    /// run for minutes, so it is left with the library and the row simply
    /// reports it. Closing this screen does not cancel it.
    ///
    /// Pressing a row that is already working calls the waiting off, so nobody
    /// is held by a spinner they cannot get out of. The server carries on.
    private func enable(_ catalog: NullfinCatalog, in group: MediaLibrary.AddonCatalogGroup) {
        if media.isImporting(catalog, in: group) {
            media.stopWaiting(for: catalog, in: group)
        } else {
            media.enableCatalog(catalog, in: group)
        }
    }

    /// An addon's name, and its server's when there is more than one.
    private func addonHeading(_ group: MediaLibrary.AddonCatalogGroup) -> String {
        (media.serverName(of: group.serverID).map { group.name + " · " + $0 } ?? group.name).uppercased()
    }

    private var emptyDetail: String {
        let several = media.profiles.count > 1
        if media.addonsUnavailable {
            return several
                ? "Your servers offer no other library or catalog, and they do not let these accounts browse their catalogs -- sign in as an administrator to switch them on from here."
                : "This server offers no other library or catalog, and it does not let this account browse its catalogs -- sign in as an administrator to switch them on from here."
        }
        return several
            ? "Your servers offer no other library or catalog."
            : "This server offers no other library or catalog."
    }

    private func countText(_ item: MediaItem) -> String? {
        guard let count = item.childCount, count > 0 else { return nil }
        return "\(count) titles"
    }

    private var rowPadding: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }
}

private struct MediaShelfRow: View {
    let title: String
    var detail: String?
    let busy: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.inter(nameSize, .semibold))
                    .lineLimit(2).multilineTextAlignment(.leading)
                if let detail {
                    Text(detail).font(.inter(detailSize))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                }
            }
            Spacer(minLength: 16)
            if busy {
                ProgressView()
            } else {
                Image(systemName: "plus.circle")
                    .font(.inter(nameSize, .semibold))
                    .foregroundStyle(LineupStyle.highlight)
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .background(LineupStyle.surface.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #else
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add " + title)
    }

    #if os(tvOS)
    private var nameSize: CGFloat { 22 }
    private var detailSize: CGFloat { 14 }
    #else
    private var nameSize: CGFloat { 17 }
    private var detailSize: CGFloat { 13 }
    #endif
}
