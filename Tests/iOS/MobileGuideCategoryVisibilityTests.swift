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

    /// The Apple TV reads one provider's hidden categories outright, and Set
    /// Up with iPhone sends the phone's across.
    func testOneProvidersHiddenCategoriesAreReadAndTravelWithSetUp() throws {
        let first = UUID(), second = UUID()
        var raw = try XCTUnwrap(MobileGuideCategoryVisibility("{}").setting(true, category: "7", provider: first))
        raw = try XCTUnwrap(MobileGuideCategoryVisibility(raw).setting(true, category: "12", provider: first))
        raw = try XCTUnwrap(MobileGuideCategoryVisibility(raw).setting(true, category: "7", provider: second))
        let visibility = MobileGuideCategoryVisibility(raw)
        XCTAssertEqual(visibility.hiddenIDs(provider: first), ["7", "12"])
        XCTAssertEqual(visibility.hiddenIDs(provider: second), ["7"])
        XCTAssertTrue(visibility.hiddenIDs(provider: UUID()).isEmpty)
        XCTAssertTrue(visibility.hiddenIDs(provider: nil).isEmpty)
        XCTAssertTrue(DeviceSetup.carries(MobileGuideCategoryVisibility.storageKey))
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

    func testTheGuidesKeptCategoryAnswerIsDroppedWhenAnyOfItsInputsChanges() {
        final class Owner {}
        let owner = Owner(), other = Owner()
        let provider = UUID()
        let sports = XtreamCategory(categoryID: "7", categoryName: "Sports")
        let news = XtreamCategory(categoryID: "8", categoryName: "News")
        let memo = MobileGuideCategoryMemo()
        func key(raw: String = "{}", library: AnyObject? = nil, profile: UUID? = nil,
                 categories: [XtreamCategory]? = nil) -> MobileGuideCategoryMemo.Key {
            .init(raw: raw, library: ObjectIdentifier(library ?? owner), profile: profile ?? provider,
                  categories: categories ?? [sports, news])
        }
        XCTAssertNil(memo.value(for: key()))
        memo.keep(.init(hidden: ["7"], visible: [news]), for: key())
        XCTAssertEqual(memo.value(for: key())?.hidden, ["7"])
        XCTAssertEqual(memo.value(for: key())?.visible, [news])
        // A different saved choice, library, provider or list of categories
        // is a different question.
        XCTAssertNil(memo.value(for: key(raw: "{\"x\":[\"7\"]}")))
        XCTAssertNil(memo.value(for: key(library: other)))
        XCTAssertNil(memo.value(for: key(profile: UUID())))
        XCTAssertNil(memo.value(for: key(categories: [sports])))
    }
}
