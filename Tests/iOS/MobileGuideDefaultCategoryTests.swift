import XCTest
@testable import LineupiOS

final class MobileGuideDefaultCategoryTests: XCTestCase {
    @MainActor
    func testHoldingACategorySavesItForRelaunchAndReturningToTheTab() throws {
        let suite = "GuideDefaultCategoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let category = XtreamCategory(categoryID: "sports-4k", categoryName: "Sports 4K")
        var tapped = false
        let item = MobileGuideCategoryMenu.item(for: category, isSelected: false, isDefault: false,
            allowsDefault: true, select: { tapped = true }, changeDefault: { id in
                let value = defaults.string(forKey: MobileGuideDefaultCategory.storageKey) ?? "{}"
                defaults.set(MobileGuideDefaultCategory.setting(id, for: profile, in: value),
                             forKey: MobileGuideDefaultCategory.storageKey)
            })
        XCTAssertEqual(item.title, "Sports 4K")
        XCTAssertEqual(item.holdItems.map(\.title), ["Set as Default"])
        XCTAssertNil(item.badge)
        item.action()
        XCTAssertTrue(tapped)
        XCTAssertNil(defaults.string(forKey: MobileGuideDefaultCategory.storageKey),
                     "A normal tap must select without changing the saved default")
        tapped = false
        let menu = MobileHoldMenu()
        menu.present(item.title, symbol: "square.stack", message: nil, items: item.holdItems)
        try XCTUnwrap(menu.request?.items.first).action()
        XCTAssertFalse(tapped, "Holding a category must not also run its normal tap")

        let relaunchedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let saved = try XCTUnwrap(relaunchedDefaults.string(forKey: MobileGuideDefaultCategory.storageKey))
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: profile, in: saved,
            categoryIDs: ["news", "sports-4k"], hasFavorites: true), .category("sports-4k"))
        XCTAssertNil(MobileGuideDefaultCategory.selectionOnEntry(.category("news"), for: profile, in: saved),
                     "Returning to Guide must restore the saved default after a temporary manual selection")
    }

    func testProvidersWithTheSameCategoryNumbersHaveIndependentDefaults() {
        let first = UUID(), second = UUID()
        let saved = MobileGuideDefaultCategory.setting("7", for: first, in: "{}")
        XCTAssertNil(MobileGuideDefaultCategory.categoryID(for: second, in: saved))
        let both = MobileGuideDefaultCategory.setting("12", for: second, in: saved)
        XCTAssertEqual(MobileGuideDefaultCategory.categoryID(for: first, in: both), "7")
        XCTAssertEqual(MobileGuideDefaultCategory.categoryID(for: second, in: both), "12")
        let removed = MobileGuideDefaultCategory.setting(nil, for: first, in: both)
        XCTAssertNil(MobileGuideDefaultCategory.categoryID(for: first, in: removed))
        XCTAssertEqual(MobileGuideDefaultCategory.categoryID(for: second, in: removed), "12")
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: first, in: removed,
            categoryIDs: ["7", "12"], hasFavorites: true), .favorites)
    }

    func testMissingAndLoadingCategoriesFallbackWithoutDiscardingTheSavedChoice() {
        let profile = UUID()
        let saved = MobileGuideDefaultCategory.setting("7", for: profile, in: "{}")
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: profile, in: saved,
            categoryIDs: [], hasFavorites: false), .all)
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: profile, in: saved,
            categoryIDs: ["other"], hasFavorites: true), .favorites)
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: profile, in: saved,
            categoryIDs: ["7"], hasFavorites: true), .category("7"),
                       "A saved choice should take effect once a delayed provider catalog arrives")
        XCTAssertEqual(MobileGuideDefaultCategory.categoryID(for: profile, in: saved), "7")
    }

    func testNoPreferenceKeepsExistingBehaviorAndGamePickingIgnoresTheDefault() {
        let profile = UUID()
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: profile, in: "{}",
            categoryIDs: ["7"], hasFavorites: false), .all)
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: profile, in: "{}",
            categoryIDs: ["7"], hasFavorites: true), .favorites)
        XCTAssertEqual(MobileGuideDefaultCategory.selectionOnEntry(.recents, for: profile, in: "{}"), .recents)
        let saved = MobileGuideDefaultCategory.setting("7", for: profile, in: "{}")
        XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: profile, in: saved,
            categoryIDs: ["7"], hasFavorites: true, isGamePicker: true), .all)
        XCTAssertEqual(MobileGuideDefaultCategory.selectionOnEntry(.category("other"), for: profile,
            in: saved, isGamePicker: true), .category("other"))
    }

    func testRemovingTheDefaultAndGamePickerMenuKeepNormalTapsSeparate() throws {
        let category = XtreamCategory(categoryID: "movies", categoryName: "Movie Channels")
        var tapped = 0
        var changes: [String?] = []
        let item = MobileGuideCategoryMenu.item(for: category, isSelected: false, isDefault: true,
            allowsDefault: true, select: { tapped += 1 }, changeDefault: { changes.append($0) })
        XCTAssertEqual(item.badge, "Default")
        XCTAssertFalse(item.isSelected, "The saved start category and the current selection are independent")
        XCTAssertEqual(item.holdItems.map(\.title), ["Remove Default"])
        try XCTUnwrap(item.holdItems.first).action()
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(changes[0])
        XCTAssertEqual(tapped, 0)

        let picker = MobileGuideCategoryMenu.item(for: category, isSelected: true, isDefault: true,
            allowsDefault: false, select: { tapped += 1 }, changeDefault: { changes.append($0) })
        XCTAssertTrue(picker.holdItems.isEmpty)
        XCTAssertNil(picker.badge)
        picker.action()
        XCTAssertEqual(tapped, 1)
        XCTAssertEqual(changes.count, 1)
    }

    func testCorruptPreferencesAndPlaylistCategoryIDsRecoverSafely() {
        let profile = UUID()
        for invalid in ["", "not json", "[]", "{\"unexpected\":42}"] {
            XCTAssertNil(MobileGuideDefaultCategory.categoryID(for: profile, in: invalid))
            XCTAssertEqual(MobileGuideDefaultCategory.initialFilter(for: profile, in: invalid,
                categoryIDs: ["1"], hasFavorites: false), .all)
        }
        let playlistID = "group: Sports / UHD | 日本語"
        let recovered = MobileGuideDefaultCategory.setting(playlistID, for: profile, in: "broken")
        XCTAssertEqual(MobileGuideDefaultCategory.categoryID(for: profile, in: recovered), playlistID)
        XCTAssertNil(MobileGuideDefaultCategory.categoryID(for: nil, in: recovered))
        XCTAssertNil(MobileGuideDefaultCategory.categoryID(for: profile,
            in: MobileGuideDefaultCategory.setting("", for: profile, in: recovered)))
    }
}
