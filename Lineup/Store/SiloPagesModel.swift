import Foundation
import Observation

/// A Silo server's pages beyond its libraries, as Silo's own app has them:
/// Home, For You -- with the viewer's Watchlist, Favorites and History -- and
/// the Calendar. Kept by the store while the server is connected, so going
/// back to one shows it as it was and reads it again quietly behind it.
@MainActor
@Observable
final class SiloPagesModel {
    /// What the Library shows: one of the server's libraries, or one of
    /// these pages.
    enum Place: String, CaseIterable, Identifiable {
        case library, home, forYou, calendar
        var id: String { rawValue }
        var title: String {
            switch self {
            case .library: "Library"
            case .home: "Home"
            case .forYou: "For You"
            case .calendar: "Calendar"
            }
        }
        var symbol: String {
            switch self {
            case .library: "square.grid.3x3"
            case .home: "house"
            case .forYou: "sparkles"
            case .calendar: "calendar"
            }
        }
    }

    /// For You's pages, as Silo's own app has them.
    enum ForYouTab: String, CaseIterable, Identifiable {
        case forYou, watchlist, favorites, history
        var id: String { rawValue }
        var title: String {
            switch self {
            case .forYou: "For You"
            case .watchlist: "Watchlist"
            case .favorites: "Favorites"
            case .history: "History"
            }
        }
        var list: SiloPersonalList? {
            switch self {
            case .forYou: nil
            case .watchlist: .watchlist
            case .favorites: .favorites
            case .history: .history
            }
        }
    }

    typealias Phase = ServerLibraryModel.Phase

    struct ListState {
        var items: [MediaItem] = []
        var next: String?
        var phase: Phase = .idle
        var loadingMore = false
    }

    let profile: MediaServerProfile
    @ObservationIgnored private let client: SiloClient
    @ObservationIgnored private let defaults: UserDefaults

    var place: Place {
        didSet {
            guard place != oldValue else { return }
            defaults.set(place.rawValue, forKey: Self.key("place", profile))
            Task { await refresh() }
        }
    }

    private(set) var home = SiloHome()
    private(set) var homePhase: Phase = .idle

    var forYouTab: ForYouTab = .forYou {
        didSet { if forYouTab != oldValue { Task { await refresh() } } }
    }
    private(set) var forYou = SiloForYou()
    private(set) var forYouPhase: Phase = .idle
    private(set) var lists: [SiloPersonalList: ListState] = [:]

    /// The first day of the week the Calendar shows.
    private(set) var week: Date
    private(set) var days: [SiloCalendarDay] = []
    private(set) var calendarPhase: Phase = .idle
    @ObservationIgnored private var calendarRead = 0

    /// What each title's card says about its file, from every list read.
    private(set) var badges: [String: ServerLibraryBadges] = [:]

    init(profile: MediaServerProfile, client: SiloClient, defaults: UserDefaults = .standard) {
        self.profile = profile
        self.client = client
        self.defaults = defaults
        place = defaults.string(forKey: Self.key("place", profile)).flatMap(Place.init) ?? .library
        week = Self.startOfWeek(Date())
    }

    private static func key(_ name: String, _ profile: MediaServerProfile) -> String {
        "Lineup.siloPages." + name + "." + profile.id.uuidString
    }

    // MARK: Reading

    /// The page in view, read again; what is showing stays until the answer
    /// is in, and a failure leaves it as it was.
    func refresh() async {
        switch place {
        case .library: return
        case .home: await loadHome()
        case .forYou:
            if let list = forYouTab.list { await loadList(list) } else { await loadForYou() }
        case .calendar: await loadCalendar()
        }
    }

    private func loadHome() async {
        if homePhase != .loaded { homePhase = .loading }
        do {
            let found = try await client.siloHome()
            home = SiloHome(rows: found.rows.map(served), badges: found.badges, dismissals: found.dismissals)
            badges.merge(found.badges) { _, new in new }
            homePhase = .loaded
        } catch {
            if homePhase != .loaded { homePhase = .failed(Self.message(error)) }
        }
    }

    private func loadForYou() async {
        if forYouPhase != .loaded { forYouPhase = .loading }
        do {
            let found = try await client.siloForYou()
            forYou = SiloForYou(rows: found.rows.map(served), badges: found.badges)
            badges.merge(found.badges) { _, new in new }
            forYouPhase = .loaded
        } catch {
            if forYouPhase != .loaded { forYouPhase = .failed(Self.message(error)) }
        }
    }

    private func loadList(_ list: SiloPersonalList) async {
        var state = lists[list] ?? ListState()
        if state.phase != .loaded { state.phase = .loading; lists[list] = state }
        do {
            let page = try await client.siloList(list, cursor: nil)
            badges.merge(page.badges) { _, new in new }
            lists[list] = ListState(items: page.items.map(served), next: page.next, phase: .loaded)
        } catch {
            guard lists[list]?.phase != .loaded else { return }
            lists[list]?.phase = .failed(Self.message(error))
        }
    }

    /// A list's next page, as its last cards come into view.
    func loadMore(_ list: SiloPersonalList) async {
        guard var state = lists[list], state.phase == .loaded, !state.loadingMore, let cursor = state.next else { return }
        state.loadingMore = true
        lists[list] = state
        defer { lists[list]?.loadingMore = false }
        guard let page = try? await client.siloList(list, cursor: cursor) else { return }
        badges.merge(page.badges) { _, new in new }
        let known = Set(state.items.map(\.id))
        lists[list]?.items += page.items.filter { !known.contains($0.id) }.map(served)
        lists[list]?.next = page.next
    }

    /// A Home row in full, for its own page: up to a few pages of it.
    func rowTitles(_ row: ServerLibraryRow) async throws -> [MediaItem] {
        guard case .section = row.source, home.rows.contains(where: { $0.id == row.id }) else { return row.items }
        var found: [MediaItem] = []
        var cursor: String?
        for _ in 0..<4 {
            let page = try await client.siloHomeRow(row, cursor: cursor)
            badges.merge(page.badges) { _, new in new }
            let known = Set(found.map(\.id))
            found += page.items.filter { !known.contains($0.id) }
            guard let next = page.next else { break }
            cursor = next
        }
        return (found.isEmpty ? row.items : found).map(served)
    }

    // MARK: Continue Watching

    /// Whether a Home card can be taken off its row.
    func canRemove(_ item: MediaItem, from row: ServerLibraryRow) -> Bool {
        home.dismissals[row.id]?[item.id] != nil
    }

    /// Takes a card off Continue Watching or Next Up, at once, and tells
    /// Silo. A show leaves both rows, as Silo's own app does; if Silo
    /// refuses, Home is read again so it shows what Silo has.
    func remove(_ item: MediaItem, from row: ServerLibraryRow) async {
        guard let dismissal = home.dismissals[row.id]?[item.id] else { return }
        let show = dismissal.surface == .nextUp ? dismissal.seriesID : item.seriesID
        home.rows = home.rows.compactMap { shown in
            var shown = shown
            guard home.dismissals[shown.id] != nil else { return shown }
            shown.items.removeAll { $0.id == item.id || (show != nil && $0.seriesID == show) }
            return shown.items.isEmpty ? nil : shown
        }
        do { try await client.siloDismiss(itemID: item.id, dismissal) }
        catch { await loadHome() }
    }

    // MARK: Calendar

    func moveWeek(by weeks: Int) {
        week = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: week) ?? week
        days = []
        calendarPhase = .idle
        Task { await loadCalendar() }
    }

    func showThisWeek() {
        guard week != Self.startOfWeek(Date()) else { return }
        week = Self.startOfWeek(Date())
        days = []
        calendarPhase = .idle
        Task { await loadCalendar() }
    }

    var isThisWeek: Bool { week == Self.startOfWeek(Date()) }

    private func loadCalendar() async {
        calendarRead += 1
        let read = calendarRead, asked = week
        if calendarPhase != .loaded { calendarPhase = .loading }
        do {
            let found = try await client.siloCalendar(from: asked, days: 7)
            guard read == calendarRead, asked == week else { return }
            days = found
            calendarPhase = .loaded
        } catch {
            guard read == calendarRead, calendarPhase != .loaded else { return }
            calendarPhase = .failed(Self.message(error))
        }
    }

    /// The Monday of the week `date` is in.
    static func startOfWeek(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// A Calendar event's title, to open: a film's own page, or an
    /// episode's show.
    func title(for event: SiloCalendarEvent) async -> MediaItem? {
        let id = event.seriesID ?? event.id
        guard let item = try? await client.item(userID: profile.userID, itemID: id) else { return nil }
        return item.servedBy(profile.id)
    }

    // MARK: Helpers

    private func served(_ row: ServerLibraryRow) -> ServerLibraryRow {
        var row = row
        row.items = row.items.map(served)
        return row
    }

    private func served(_ item: MediaItem) -> MediaItem {
        item.serverID == profile.id ? item : item.servedBy(profile.id)
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription, !text.isEmpty { return text }
        return "Silo didn't answer. Check that it's running and reachable."
    }
}
