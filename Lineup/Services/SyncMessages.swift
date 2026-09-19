import Foundation

// One rule, in four places: say a viewer is waiting only when they are.
//
// Two screens on the phone and the same two on the television. The rule was
// written for the phone and then written again, differently and wrongly, for
// the set -- so it lives here, where both targets compile it, rather than
// being described twice and agreed on never.
//
// A message about waiting is honest when there is nothing behind it to use,
// and misleading when there is. The app restores its channels and its guide
// from cache in about a second and then refreshes behind them, which is the
// case both screens were getting wrong -- announcing, for as long as the
// refresh took, a wait that had been over since the first second.

/// Which of the Live screen's three waits to say, if any.
///
/// What decides between the loud line and the quiet one is whether there are
/// channels on screen, not which function started the work. Keying off the
/// background-refresh flag looked the same in the one case it was written for
/// and was wrong everywhere else: that flag is raised by the launch refresh
/// alone, so a schedule poll, a score update, or any matching pass fell
/// through to the loud pulsing line -- over a tab with a stream playing in it.
enum LiveSyncBanner: Equatable {
    /// Nothing on screen yet. The only wait a viewer genuinely has to sit out.
    case initialSync
    /// Everything on screen works; a refresh is running behind it.
    case background
    /// Work in flight with no cache behind it to fall back on.
    case refreshing
    case none

    static func choose(isInitialProviderSync: Bool, hasContent: Bool,
                       isScheduleLoading: Bool, isLoading: Bool,
                       channelsAreSyncing: Bool) -> LiveSyncBanner {
        if isInitialProviderSync && !hasContent { return .initialSync }
        guard isScheduleLoading || isLoading || channelsAreSyncing else { return .none }
        // Channels on screen are channels that play. Whatever is still running
        // is the app's business, not the viewer's.
        return hasContent ? .background : .refreshing
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
enum GuideSyncStatus {
    static func isWaiting(hasListings: Bool, isLoading: Bool, isGuideLoading: Bool) -> Bool {
        (isLoading || isGuideLoading) && !hasListings
    }
}
