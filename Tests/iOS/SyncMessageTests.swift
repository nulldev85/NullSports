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

/// The Guide follows the same rule, and was breaking it more quietly.
final class GuideStatusTests: XCTestCase {
    // The case that was wrong: listings restored from cache in a second, and
    // a spinner reading "Updating guide…" above them for the rest of the
    // refresh. The Live tab already says a refresh is running; the Guide does
    // not need to say it again over a guide that works.
    func testAGuideAlreadyOnScreenDoesNotAnnounceTheRefresh() {
        XCTAssertFalse(MobileGuideStatus.isWaiting(hasListings: true, isLoading: false,
                                                   isGuideLoading: true))
        XCTAssertFalse(MobileGuideStatus.isWaiting(hasListings: true, isLoading: true,
                                                   isGuideLoading: true))
    }

    // The real wait, and the reason the spinner exists: without it the rows
    // behind read "No listing" against every channel while the guide is still
    // being read.
    func testAnEmptyGuideStillSaysItIsComing() {
        XCTAssertTrue(MobileGuideStatus.isWaiting(hasListings: false, isLoading: false,
                                                  isGuideLoading: true))
        XCTAssertTrue(MobileGuideStatus.isWaiting(hasListings: false, isLoading: true,
                                                  isGuideLoading: false))
    }

    func testNothingInFlightSaysNothing() {
        XCTAssertFalse(MobileGuideStatus.isWaiting(hasListings: false, isLoading: false,
                                                   isGuideLoading: false))
        XCTAssertFalse(MobileGuideStatus.isWaiting(hasListings: true, isLoading: false,
                                                   isGuideLoading: false))
    }
}
