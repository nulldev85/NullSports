#if os(tvOS)
import SwiftUI

struct TVSiloLibraryCard: View {
    @Environment(MediaLibrary.self) private var media
    let item: MediaItem
    var badges: ServerLibraryBadges? = nil
    let open: (MediaItem) -> Void
    var leadingChoices: () -> [TVChoice] = { [] }

    var body: some View {
        if item.opensPage {
            TVSelectable(drawsFocusChrome: false, action: { open(item) }) {
                MediaItemCard(item: item)
                    .overlay { ServerLibraryBadgesOverlay(badges: badges) }
            }
            .tvHoldMenu(item.name, symbol: "film") { leadingChoices() + media.tvCardChoices(for: item) }
        } else {
            MediaPlayableCard(item: item, leadingTVChoices: leadingChoices)
                .overlay { ServerLibraryBadgesOverlay(badges: badges) }
        }
    }
}

struct TVSiloPage: View {
    let model: SiloPagesModel
    let open: (MediaItem) -> Void
    let seeAll: (ServerLibraryRow) -> Void

    var body: some View {
        switch model.place {
        case .library:
            EmptyView()
        case .home:
            phase(model.homePhase, empty: model.home.rows.isEmpty ? "Your Silo Home is empty." : nil) {
                ForEach(model.home.rows) { row in
                    TVSiloShelf(model: model, row: row, open: open,
                                seeAll: row.source == .fixed ? nil : { seeAll(row) })
                }
            }
        case .forYou:
            HStack(spacing: 18) {
                ForEach(SiloPagesModel.ForYouTab.allCases) { tab in
                    TVServerLibraryChip(title: tab.title, brand: model.profile.brand,
                                        chosen: model.forYouTab == tab) { model.forYouTab = tab }
                }
            }
            .padding(.horizontal, 80)
            .lineupFocusRegion()
            if let list = model.forYouTab.list {
                personalList(list)
            } else {
                phase(model.forYouPhase, empty: model.forYou.rows.isEmpty ? "Silo has no recommendations yet." : nil) {
                    ForEach(model.forYou.rows) { row in
                        TVSiloShelf(model: model, row: row, open: open)
                    }
                }
            }
        case .calendar:
            TVSiloCalendar(model: model, open: open)
        }
    }

    private func personalList(_ list: SiloPersonalList) -> some View {
        let state = model.lists[list] ?? SiloPagesModel.ListState()
        return phase(state.phase, empty: state.items.isEmpty ? "Your Silo \(list.title.lowercased()) is empty." : nil) {
            LazyVGrid(columns: tvSiloColumns, spacing: 48) {
                ForEach(state.items, id: \.libraryKey) { item in
                    TVSiloLibraryCard(item: item, badges: model.badges[item.id], open: open)
                        .onAppear {
                            if item.id == state.items.last?.id { Task { await model.loadMore(list) } }
                        }
                }
            }
            .padding(.horizontal, 80)
            .lineupFocusRegion()
            if state.loadingMore { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    @ViewBuilder
    private func phase<Content: View>(_ phase: SiloPagesModel.Phase, empty: String?,
                                     @ViewBuilder content: () -> Content) -> some View {
        switch phase {
        case .failed(let message):
            TVSiloStatus(message: message) { Task { await model.refresh() } }
        case .loaded:
            if let empty { TVSiloStatus(message: empty) }
            else { content() }
        default:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
        }
    }
}

private let tvSiloColumns = [GridItem(.adaptive(minimum: 240, maximum: 290), spacing: 40, alignment: .top)]

struct TVSiloStatus: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            Text(message).font(.inter(24)).foregroundStyle(LineupPanelStyle.quiet)
                .multilineTextAlignment(.center)
            if let retry {
                TVServerLibraryChip(title: "Try Again", symbol: "arrow.clockwise", chosen: false, action: retry)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

private struct TVSiloShelf: View {
    let model: SiloPagesModel
    let row: ServerLibraryRow
    let open: (MediaItem) -> Void
    var seeAll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(row.title).font(.inter(30, .bold)).padding(.horizontal, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(row.items, id: \.libraryKey) { item in
                        TVSiloLibraryCard(item: item, badges: model.badges[item.id], open: open) {
                            model.homeChoices(for: item, in: row)
                        }
                        .frame(width: 240)
                    }
                    if let seeAll {
                        TVServerLibraryChip(title: "See All", symbol: "chevron.right", chosen: false, action: seeAll)
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .lineupFocusRegion()
        }
    }
}

struct TVSiloHomeRowScreen: View {
    let model: SiloPagesModel
    let row: ServerLibraryRow
    @State private var items: [MediaItem]?
    @State private var failure: String?
    @State private var pushed: MediaItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text(row.title).font(.inter(40, .bold))
                if let items {
                    LazyVGrid(columns: tvSiloColumns, spacing: 48) {
                        ForEach(items, id: \.libraryKey) { item in
                            TVSiloLibraryCard(item: item, badges: model.badges[item.id], open: { pushed = $0 }) {
                                model.homeChoices(for: item, in: row) {
                                    itemsAfterRemoval()
                                }
                            }
                        }
                    }
                    .lineupFocusRegion()
                } else if let failure {
                    TVSiloStatus(message: failure) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 40)
        }
        .navigationDestination(item: $pushed) { MediaBrowseDestination(item: $0) }
        .environment(\.mediaStreamScope, model.profile.id)
        .background(LineupStyle.background.ignoresSafeArea())
        .task { if items == nil { await load() } }
    }

    private func itemsAfterRemoval() {
        let shown = Set(model.home.rows.first(where: { $0.id == row.id })?.items.map(\.id) ?? [])
        items?.removeAll { model.canRemove($0, from: row) && !shown.contains($0.id) }
    }

    private func load() async {
        failure = nil
        do { items = try await model.rowTitles(row) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private extension SiloPagesModel {
    func homeChoices(for item: MediaItem, in row: ServerLibraryRow, onRemove: @escaping () -> Void = {}) -> [TVChoice] {
        guard let dismissal = home.dismissals[row.id]?[item.id] else { return [] }
        let title = dismissal.surface == .nextUp ? "Remove from Next Up" : "Remove from Continue Watching"
        return [TVChoice(title, symbol: "rectangle.stack.badge.minus", isDestructive: true) {
            Task {
                await remove(item, from: row)
                onRemove()
            }
        }]
    }
}

private struct TVSiloCalendar: View {
    let model: SiloPagesModel
    let open: (MediaItem) -> Void
    @State private var selectedDay: String?
    @State private var opening = false
    @State private var unavailable = false

    private var weekDays: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: model.week) }
    }

    private var activeDay: String {
        selectedDay ?? Self.dateKey(model.isThisWeek ? Date() : model.week)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                TVServerLibraryChip(title: "Previous Week", symbol: "chevron.left", chosen: false) {
                    model.moveWeek(by: -1)
                }
                if !model.isThisWeek {
                    TVServerLibraryChip(title: "This Week", symbol: "calendar", chosen: false, action: model.showThisWeek)
                }
                TVServerLibraryChip(title: "Next Week", symbol: "chevron.right", chosen: false) {
                    model.moveWeek(by: 1)
                }
            }
            .lineupFocusRegion()
            HStack(spacing: 12) {
                ForEach(weekDays, id: \.self) { date in
                    let key = Self.dateKey(date)
                    TVServerLibraryChip(title: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                        brand: model.profile.brand, chosen: key == activeDay) {
                        selectedDay = key
                    }
                }
            }
            .lineupFocusRegion()
            events
        }
        .padding(.horizontal, 80)
        .onChange(of: model.week) { _, week in
            selectedDay = Self.dateKey(model.isThisWeek ? Date() : week)
        }
        .lineupMessage("Title Unavailable", symbol: "calendar", isPresented: $unavailable,
                       message: "Silo couldn't open this title. It may not be in your library yet.")
    }

    @ViewBuilder
    private var events: some View {
        switch model.calendarPhase {
        case .failed(let message):
            TVSiloStatus(message: message) { Task { await model.refresh() } }
        case .loaded:
            let events = model.days.first { $0.date == activeDay }?.events ?? []
            if events.isEmpty {
                TVSiloStatus(message: "No Silo calendar entries for this day.")
            } else {
                ForEach(events) { event in
                    TVSelectable(scale: 1.02, action: { openEvent(event) }) {
                        HStack(spacing: 18) {
                            LineupArtView(url: event.posterURL, width: 60) { image in
                                if let image { image.resizable().scaledToFill() }
                                else { LineupStyle.surface }
                            }
                            .frame(width: 60, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.title).font(.inter(26, .bold))
                                let detail = [event.episodeCode, event.episodeTitle,
                                              event.airsAt?.formatted(date: .omitted, time: .shortened)]
                                    .compactMap { $0 } + event.badges
                                if !detail.isEmpty {
                                    Text(detail.joined(separator: " · "))
                                        .font(.inter(20)).foregroundStyle(LineupPanelStyle.quiet)
                                }
                            }
                            Spacer(minLength: 0)
                            if event.watched { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Watched") }
                        }
                        .padding(12)
                        .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        default:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
        }
    }

    private func openEvent(_ event: SiloCalendarEvent) {
        guard !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            if let title = await model.title(for: event) { open(title) }
            else { unavailable = true }
        }
    }

    private static func dateKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct TVSiloPersonRoute: Hashable {
    let profileID: UUID
    let personID: String
    let name: String
}

struct TVSiloPersonScreen: View {
    @Environment(MediaLibrary.self) private var media
    let route: TVSiloPersonRoute
    @State private var person: SiloPerson?
    @State private var failure: String?
    @State private var pushed: MediaItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top, spacing: 30) {
                    LineupArtView(url: person?.photoURL, width: 240) { image in
                        if let image { image.resizable().scaledToFill() }
                        else { LineupStyle.surface }
                    }
                    .frame(width: 180, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 14) {
                        Text(person?.name ?? route.name).font(.inter(44, .bold))
                        if let bio = person?.bio, !bio.isEmpty {
                            Text(bio).font(.inter(24)).foregroundStyle(LineupPanelStyle.quiet)
                        }
                    }
                }
                if let person {
                    Text("On Your Server").font(.inter(30, .bold))
                    if person.titles.isEmpty {
                        TVSiloStatus(message: "No titles were found on this server.")
                    } else {
                        LazyVGrid(columns: tvSiloColumns, spacing: 48) {
                            ForEach(person.titles, id: \.libraryKey) { title in
                                TVSiloLibraryCard(item: title.servedBy(route.profileID), open: { pushed = $0 })
                            }
                        }
                        .lineupFocusRegion()
                    }
                } else if let failure {
                    TVSiloStatus(message: failure) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 40)
        }
        .background(LineupStyle.background.ignoresSafeArea())
        .navigationDestination(item: $pushed) { MediaBrowseDestination(item: $0) }
        .environment(\.mediaStreamScope, route.profileID)
        .task(id: route) { if person == nil { await load() } }
    }

    private func load() async {
        failure = nil
        guard let profile = media.profiles.first(where: { $0.id == route.profileID }),
              let client = media.siloClient(for: profile) else {
            failure = "This Silo server isn't connected anymore."
            return
        }
        do { person = try await client.siloPerson(id: route.personID) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

struct TVSiloBoxSetRoute: Hashable {
    let profileID: UUID
    let set: SiloBoxSet

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profileID == rhs.profileID && lhs.set.id == rhs.set.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profileID)
        hasher.combine(set.id)
    }
}

struct TVSiloBoxSetScreen: View {
    let route: TVSiloBoxSetRoute
    @State private var pushed: MediaItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Text(route.set.title).font(.inter(44, .bold))
                if let years = route.set.years {
                    Text(years).font(.inter(23, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                }
                if let overview = route.set.overview, !overview.isEmpty {
                    Text(overview).font(.inter(24)).foregroundStyle(LineupPanelStyle.quiet)
                }
                LazyVGrid(columns: tvSiloColumns, spacing: 48) {
                    ForEach(route.set.items, id: \.libraryKey) { title in
                        TVSiloLibraryCard(item: title.servedBy(route.profileID), open: { pushed = $0 })
                    }
                }
                .lineupFocusRegion()
            }
            .padding(.horizontal, 80).padding(.vertical, 40)
        }
        .background(LineupStyle.background.ignoresSafeArea())
        .navigationDestination(item: $pushed) { MediaBrowseDestination(item: $0) }
        .environment(\.mediaStreamScope, route.profileID)
    }
}
#endif
