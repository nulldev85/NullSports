import XCTest
@testable import LineupiOS

/// Which wait the Live tab announces. The order these are asked in is the
/// whole logic, and getting it wrong is not a crash -- it is a launch that
/// works perfectly while telling the viewer it does not.
final class LiveBannerTests: XCTestCase {
    // The case that was wrong: a refresh behind restored cache sets the
    // background flag *and* the syncing one, so asking about syncing first
    // made the quiet banner unreachable. Channels were on screen in a second
    // and the tab said "refreshing streams" for another ninety.
    func testARefreshBehindRestoredCacheIsTheQuietOne() {
        XCTAssertEqual(
            MobileLiveBanner.choose(isInitialProviderSync: false, isRefreshingInBackground: true,
                                    isScheduleLoading: false, isLoading: false,
                                    channelsAreSyncing: true),
            .background,
            "Everything on screen already works; saying otherwise for a minute is the bug")
    }

    // Nothing restored means nothing to use, and that wait is worth explaining
    // at length. It outranks everything.
    func testAFirstSyncOutranksEverything() {
        XCTAssertEqual(
            MobileLiveBanner.choose(isInitialProviderSync: true, isRefreshingInBackground: true,
                                    isScheduleLoading: true, isLoading: true,
                                    channelsAreSyncing: true),
            .initialSync)
    }

    // Work in flight with no background refresh behind it is the loud one:
    // there is no cache underneath, so the screen really is waiting.
    func testWorkWithNoCacheBehindItStillSaysSo() {
        for (schedule, loading, syncing) in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertEqual(
                MobileLiveBanner.choose(isInitialProviderSync: false, isRefreshingInBackground: false,
                                        isScheduleLoading: schedule, isLoading: loading,
                                        channelsAreSyncing: syncing),
                .refreshing)
        }
    }

    func testAnIdleTabSaysNothing() {
        XCTAssertEqual(
            MobileLiveBanner.choose(isInitialProviderSync: false, isRefreshingInBackground: false,
                                    isScheduleLoading: false, isLoading: false,
                                    channelsAreSyncing: false),
            .none)
    }
}
