import Foundation

/// Where a link from outside the app asked to go: a Top Shelf item, a widget,
/// anything else that opens a `lineup://` URL.
///
/// The router only holds the request. Choosing the tab, opening the game or
/// starting playback belongs to the screens that already know how, and they
/// read `pending` and clear it once they have acted on it. Holding it rather
/// than delivering it as an event matters at launch: a link that cold-starts
/// the app arrives before those screens exist, and it has to still be here
/// when they do.
@MainActor
final class LineupLinkRouter: ObservableObject {
    static let shared = LineupLinkRouter()

    /// The link waiting to be acted on. Whoever acts on it sets this back to
    /// nil, so the same link is not followed twice.
    @Published var pending: LineupLink?

    private init() {}

    /// Takes a URL the system handed the app. Answers whether it was one of
    /// Lineup's; anything else is ignored and leaves `pending` as it was.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = LineupLink(url: url) else { return false }
        pending = link
        return true
    }
}
