import Foundation

// One rule, in two places: say a viewer is waiting only when they are.
//
// A message about waiting is honest when there is nothing behind it to use,
// and misleading when there is. The app restores its channels and its guide
// from cache in about a second and then refreshes behind them, which is the
// case both screens were getting wrong -- announcing, for as long as the
// refresh took, a wait that had been over since the first second.

/// Which of the Live tab's three waits to say, if any.
///
/// Three states overlap, and the order they are asked in decides what a viewer
/// is told. A refresh running behind restored cache sets *both* the background
/// flag and the general syncing one, so asking about syncing first made the
/// quiet banner unreachable. The order is the whole logic, which is why it
/// lives somewhere a test can reach.
enum MobileLiveBanner: Equatable {
    /// Nothing on screen yet. The only wait a viewer genuinely has to sit out.
    case initialSync
    /// Everything on screen works; a refresh is running behind it.
    case background
    /// Work in flight with no cache behind it to fall back on.
    case refreshing
    case none

    static func choose(isInitialProviderSync: Bool, isRefreshingInBackground: Bool,
                       isScheduleLoading: Bool, isLoading: Bool,
                       channelsAreSyncing: Bool) -> MobileLiveBanner {
        if isInitialProviderSync { return .initialSync }
        if isRefreshingInBackground { return .background }
        if isScheduleLoading || isLoading || channelsAreSyncing { return .refreshing }
        return .none
    }
}

/// Whether the Guide should say it is updating.
///
/// The same rule as above, and the Guide was breaking it more quietly: a
/// spinner reading "Updating guide…" sat above a guide that was already on
/// screen and already scrollable, for the whole of a refresh.
///
/// It stays for the one case that is a real wait -- listings not restored yet,
/// where the rows behind it would otherwise read "No listing" against every
/// channel. The Live tab's background line covers the other case, which is
/// where a refresh belongs: mentioned once, quietly, not on every screen.
enum MobileGuideStatus {
    static func isWaiting(hasListings: Bool, isLoading: Bool, isGuideLoading: Bool) -> Bool {
        (isLoading || isGuideLoading) && !hasListings
    }
}
