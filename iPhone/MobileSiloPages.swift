import SwiftUI

/// Silo's Home, For You and Calendar inside its Library, as Silo's own app
/// has them, drawn the way the rest of the server's Library is.
struct MobileSiloPage: View {
    @Environment(MediaLibrary.self) private var media
    let model: SiloPagesModel
    let open: (MediaItem) -> Void
    let seeAll: (ServerLibraryRow) -> Void

    var body: some View {
        switch model.place {
        case .home: home
        case .forYou: forYou
        case .calendar: MobileSiloCalendar(model: model, open: open)
        case .library: EmptyView()
        }
    }

    // MARK: Home

    @ViewBuilder
    private var home: some View {
        switch model.homePhase {
        case .failed(let message):
            MobileSiloState.failure(message) { Task { await model.refresh() } }
        case .loaded where model.home.rows.isEmpty:
            MobileSiloState.empty("Nothing on Home yet. Start watching something and it'll show up here.")
        case .loaded:
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(model.home.rows) { row in
                    MobileSiloRow(row: row, badges: model.badges, seeAll: { seeAll(row) }, open: open) { item in
                        guard model.canRemove(item, from: row) else { return [] }
                        let nextUp = model.home.dismissals[row.id]?[item.id]?.surface == .nextUp
                        return [MobileMenuItem(nextUp ? "Remove from Next Up" : "Remove from Continue Watching",
                                               symbol: "rectangle.stack.badge.minus", isDestructive: true) {
                            Task { await model.remove(item, from: row) }
                        }]
                    }
                }
            }
        default:
            MobileSiloState.loading
        }
    }

    // MARK: For You

    private var forYou: some View {
        VStack(alignment: .leading, spacing: 0) {
            MobileSiloTabs(tabs: SiloPagesModel.ForYouTab.allCases.map { MobileSiloTab(id: $0.id, title: $0.title) },
                           chosen: model.forYouTab.id, brand: model.profile.brand) { id in
                if let tab = SiloPagesModel.ForYouTab(rawValue: id) { model.forYouTab = tab }
            }
            .padding(.bottom, 22)
            if let list = model.forYouTab.list {
                personalList(list)
            } else {
                recommendations
            }
        }
    }

    @ViewBuilder
    private var recommendations: some View {
        switch model.forYouPhase {
        case .failed(let message):
            MobileSiloState.failure(message) { Task { await model.refresh() } }
        case .loaded where model.forYou.rows.isEmpty:
            MobileSiloState.empty("Silo is still learning what you like. Watch a few things and check back.")
        case .loaded:
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(model.forYou.rows) { row in
                    MobileSiloRow(row: row, badges: model.badges, seeAll: nil, open: open) { _ in [] }
                }
            }
        default:
            MobileSiloState.loading
        }
    }

    private static func emptyText(_ list: SiloPersonalList) -> String {
        switch list {
        case .watchlist: "Your Watchlist is empty. Tap the bookmark on a title to save it for later."
        case .favorites: "No favorites yet. Tap the heart on a title to add it."
        case .history: "Nothing watched yet."
        }
    }

    @ViewBuilder
    private func personalList(_ list: SiloPersonalList) -> some View {
        let state = model.lists[list] ?? SiloPagesModel.ListState()
        switch state.phase {
        case .failed(let message):
            MobileSiloState.failure(message) { Task { await model.refresh() } }
        case .loaded where state.items.isEmpty:
            MobileSiloState.empty(Self.emptyText(list))
        case .loaded:
            LazyVGrid(columns: MobileServerLibraryGrid.columns, spacing: 22) {
                ForEach(state.items, id: \.libraryKey) { item in
                    MobileSiloCell(item: item, badges: model.badges[item.id], open: open) { [] }
                        .onAppear {
                            if item.id == state.items.last?.id { Task { await model.loadMore(list) } }
                        }
                }
            }
            .padding(.horizontal, 16)
            if state.loadingMore {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        default:
            MobileSiloState.loading
        }
    }
}

// MARK: - Pieces

/// A row of titles, with its name over it, leading to the whole row when
/// there is more of it to see.
private struct MobileSiloRow: View {
    let row: ServerLibraryRow
    let badges: [String: ServerLibraryBadges]
    let seeAll: (() -> Void)?
    let open: (MediaItem) -> Void
    let menu: (MediaItem) -> [MobileMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let seeAll {
                    Button(action: seeAll) {
                        HStack(spacing: 8) {
                            title
                            Image(systemName: "chevron.right")
                                .font(.system(size: 17, weight: .bold)).foregroundStyle(LineupPanelStyle.quiet)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    title
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items, id: \.libraryKey) { item in
                        MobileSiloCell(item: item, badges: badges[item.id], open: open) { menu(item) }
                            .frame(width: 128)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var title: some View {
        Text(row.title).font(.inter(24, .heavy)).foregroundStyle(LineupStyle.text).lineLimit(1)
    }
}

/// A title's card: a film or show opens its page, an episode plays.
struct MobileSiloCell: View {
    @Environment(MediaLibrary.self) private var media
    let item: MediaItem
    let badges: ServerLibraryBadges?
    let open: (MediaItem) -> Void
    var menu: () -> [MobileMenuItem] = { [] }

    var body: some View {
        Group {
            if item.opensPage {
                MediaItemCard(item: item)
                    .lineupHoldMenu(item.name, symbol: "film", items: { menu() + media.cardMenuItems(for: item) }) {
                        open(item)
                    }
            } else {
                MediaPlayableCard(item: item, leadingMenuItems: menu)
            }
        }
        .overlay { ServerLibraryBadgesOverlay(badges: badges) }
    }
}

struct MobileSiloTab: Identifiable, Hashable {
    let id: String
    let title: String
}

/// The capsules along the top of a page, as the Library's own.
struct MobileSiloTabs: View {
    let tabs: [MobileSiloTab]
    let chosen: String
    let brand: MediaServerBrand
    let choose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tabs) { tab in
                    let isChosen = tab.id == chosen
                    Button { choose(tab.id) } label: {
                        Text(tab.title)
                            .font(.inter(17, isChosen ? .bold : .semibold))
                            .foregroundStyle(isChosen ? LineupStyle.text : LineupPanelStyle.quiet)
                            .padding(.horizontal, 22).frame(height: 44)
                            .background {
                                if isChosen {
                                    ZStack {
                                        Capsule().fill(LineupStyle.surface)
                                        Capsule().fill(LinearGradient(colors: brand.cardTints.map { $0.opacity(0.19) },
                                                                      startPoint: .leading, endPoint: .trailing))
                                    }
                                } else {
                                    Capsule().fill(LineupStyle.surface)
                                }
                            }
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
                            .animation(.easeOut(duration: 0.18), value: isChosen)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Loading, empty and failed, as the Library draws them.
enum MobileSiloState {
    static var loading: some View {
        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    static func empty(_ text: String) -> some View {
        Text(text).font(.inter(16)).foregroundStyle(LineupPanelStyle.quiet)
            .frame(maxWidth: .infinity).padding(.vertical, 60).padding(.horizontal, 24)
            .multilineTextAlignment(.center)
    }

    static func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Text(message).font(.inter(15)).foregroundStyle(LineupPanelStyle.quiet)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry).lineupProminentButton()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }
}

// MARK: - Calendar

/// A week of what airs and comes out, day by day, as Silo's own Calendar.
private struct MobileSiloCalendar: View {
    let model: SiloPagesModel
    let open: (MediaItem) -> Void
    @State private var opening: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            weekBar
            switch model.calendarPhase {
            case .failed(let message):
                MobileSiloState.failure(message) { Task { await model.refresh() } }
            case .loaded where model.days.allSatisfy(\.events.isEmpty):
                MobileSiloState.empty("Nothing airs or comes out this week.")
            case .loaded:
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(model.days.filter { !$0.events.isEmpty }) { day in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(Self.dayTitle(day.date)).font(.inter(20, .heavy)).foregroundStyle(LineupStyle.text)
                                .padding(.horizontal, 16)
                            ForEach(day.events) { event in eventRow(event) }
                        }
                    }
                }
            default:
                MobileSiloState.loading
            }
        }
    }

    private var weekBar: some View {
        HStack(spacing: 10) {
            arrow("chevron.left", label: "Previous week") { model.moveWeek(by: -1) }
            VStack(spacing: 2) {
                Text(Self.weekTitle(model.week)).font(.inter(17, .bold)).foregroundStyle(LineupStyle.text)
                if !model.isThisWeek {
                    Button("Back to This Week") { model.showThisWeek() }
                        .font(.inter(13, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                }
            }
            .frame(maxWidth: .infinity)
            arrow("chevron.right", label: "Next week") { model.moveWeek(by: 1) }
        }
        .padding(.horizontal, 16)
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(LineupStyle.text)
                .frame(width: 44, height: 44).background(LineupStyle.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func eventRow(_ event: SiloCalendarEvent) -> some View {
        Button {
            guard opening == nil else { return }
            opening = event.id
            Task {
                if let title = await model.title(for: event) { open(title) }
                opening = nil
            }
        } label: {
            HStack(spacing: 14) {
                LineupArtView(url: event.posterURL, width: 60) { loaded in
                    if let loaded {
                        loaded.resizable().scaledToFill()
                    } else {
                        LineupStyle.surface
                    }
                }
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.inter(16, .bold)).foregroundStyle(LineupStyle.text).lineLimit(2)
                    if let code = event.episodeCode {
                        Text([code, event.episodeTitle].compactMap { $0 }.joined(separator: " · "))
                            .font(.inter(14, .medium)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if let time = event.airsAt {
                            Text(time.formatted(date: .omitted, time: .shortened))
                        } else if event.kind == "movie" {
                            Text("Movie")
                        }
                        ForEach(event.badges, id: \.self) { badge in
                            Text(badge).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(LineupStyle.surface, in: Capsule())
                        }
                    }
                    .font(.inter(12, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                }
                Spacer(minLength: 0)
                if opening == event.id {
                    ProgressView()
                } else if event.watched {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                        .foregroundStyle(LineupPanelStyle.quiet).accessibilityLabel("Watched")
                }
            }
            .padding(10)
            .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    /// "Today", "Tomorrow", or "Wednesday, Nov 19".
    static func dayTitle(_ date: String) -> String {
        guard let day = dayFormat.date(from: date) else { return date }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// "Nov 17 – 23", or across a month's end "Nov 30 – Dec 6".
    static func weekTitle(_ start: Date) -> String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        let sameMonth = Calendar.current.isDate(start, equalTo: end, toGranularity: .month)
        let first = start.formatted(.dateTime.month(.abbreviated).day())
        let last = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
        return first + " – " + last
    }
}
