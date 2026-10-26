import XCTest
@testable import LineupiOS

final class MobileGuideCategoryVisibilityTests: XCTestCase {
    func testVisibilityPersistsPerNativeProviderCategoryAndCanBeRestored() throws {
        let first = UUID(), second = UUID()
        let category = "group: Sports | UHD / 日本語"
        let saved = try XCTUnwrap(MobileGuideCategoryVisibility("{}").setting(true, category: category, provider: first))
        let suite = "GuideVisibility." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved, forKey: MobileGuideCategoryVisibility.storageKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite)?.string(forKey: MobileGuideCategoryVisibility.storageKey))
        let preferences = MobileGuideCategoryVisibility(reopened)
        XCTAssertTrue(preferences.isHidden(category, provider: first))
        XCTAssertFalse(preferences.isHidden(category, provider: second))
        let both = try XCTUnwrap(preferences.setting(true, category: "7", provider: second))
        let restored = try XCTUnwrap(MobileGuideCategoryVisibility(both).setting(false, category: category, provider: first))
        XCTAssertFalse(MobileGuideCategoryVisibility(restored).isHidden(category, provider: first))
        XCTAssertTrue(MobileGuideCategoryVisibility(restored).isHidden("7", provider: second))
    }

    func testCombinedGuideHidesOnlyTheOfferingProviderAndRetainsPersonalAndSportsChoices() throws {
        let first = UUID(), second = UUID()
        let a = first.uuidString + "|7", b = second.uuidString + "|7"
        let categories = [XtreamCategory(categoryID: a, categoryName: "One · Sports"), XtreamCategory(categoryID: b, categoryName: "Two · Sports")]
        let raw = try XCTUnwrap(MobileGuideCategoryVisibility("{}").setting(true, category: "7", provider: first))
        let hidden = MobileGuideCategoryVisibility(raw).hiddenDisplayIDs(in: categories) { id in
            (id == a ? first : second, "7")
        }
        XCTAssertEqual(hidden, [a])
        let streams = [a, b].enumerated().map { index, category in
            XtreamStream(num: index + 1, name: "Feed \(index)", streamType: "live", streamID: index,
                streamIcon: nil, epgChannelID: nil, categoryID: category)
        }
        XCTAssertEqual(MobileGuideCategoryVisibility.filtered(streams, hidden: hidden, personalList: false, gamePicker: false).map(\.categoryID), [b])
        XCTAssertEqual(MobileGuideCategoryVisibility.filtered(streams, hidden: hidden, personalList: true, gamePicker: false), streams)
        XCTAssertEqual(MobileGuideCategoryVisibility.filtered(streams, hidden: hidden, personalList: false, gamePicker: true), streams)
    }

    func testHidingTheDefaultDoesNotDeleteItOrStrandTheGuide() throws {
        let provider = UUID()
        let saved = MobileGuideDefaultCategory.setting("7", for: provider, in: "{}")
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: provider, in: saved, categoryIDs: [], hasFavorites: true), .favorites)
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: provider, in: saved, categoryIDs: [], hasFavorites: false), .all)
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: provider, in: saved, categoryIDs: ["7"], hasFavorites: true), .category("7"))
        for invalid in ["broken", "[]", "{\"bad\":42}"] {
            XCTAssertFalse(MobileGuideCategoryVisibility(invalid).isHidden("7", provider: provider))
        }
        XCTAssertNil(MobileGuideCategoryVisibility("{}").setting(true, category: "7", provider: nil))
    }
}
