import Foundation

/// Which of the Live tab's three waits to say, if any.
///
/// Three states overlap, and the order they are asked in decides what a viewer
/// is told. A refresh running behind restored cache sets *both* the background
/// flag and the general syncing one, so asking about syncing first made the
/// quiet banner unreachable: a launch that had been usable since its first
/// second spent a minute and a half insisting it was still refreshing. The
/// order is the whole logic, which is why it lives somewhere a test can reach.
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
