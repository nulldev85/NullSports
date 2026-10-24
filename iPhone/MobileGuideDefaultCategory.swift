import Foundation

/// Category IDs belong to a provider, not to the device-wide channel catalog.
enum MobileGuideDefaultCategory {
    static let storageKey = "lineup.mobile.guide.defaultCategories.v1"

    private static func categories(in value: String) -> [String: String] {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    static func categoryID(for profileID: UUID?, in value: String) -> String? {
        guard let profileID, let id = categories(in: value)[profileID.uuidString], !id.isEmpty else { return nil }
        return id
    }

    static func setting(_ categoryID: String?, for profileID: UUID, in value: String) -> String {
        var saved = categories(in: value)
        saved[profileID.uuidString] = categoryID.flatMap { $0.isEmpty ? nil : $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(saved), let result = String(data: data, encoding: .utf8) else { return value }
        return result
    }

    static func initialFilter(for profileID: UUID?, in value: String, categoryIDs: [String],
                              hasFavorites: Bool, isGamePicker: Bool = false) -> MobileGuideFilter {
        guard !isGamePicker else { return .all }
        if let id = categoryID(for: profileID, in: value), categoryIDs.contains(id) { return .category(id) }
        // A removed category must never strand the user on an empty Guide.
        return hasFavorites ? .favorites : .all
    }

    static func selectionOnEntry(_ selection: MobileGuideFilter?, for profileID: UUID?, in value: String,
                                 isGamePicker: Bool = false) -> MobileGuideFilter? {
        guard !isGamePicker, categoryID(for: profileID, in: value) != nil else { return selection }
        // Nil lets initialFilter validate the saved category against the latest
        // catalog, including a catalog still loading on a cold launch.
        return nil
    }
}

enum MobileGuideCategoryMenu {
    static func item(for category: XtreamCategory, isSelected: Bool, isDefault: Bool,
                     allowsDefault: Bool, select: @escaping () -> Void,
                     changeDefault: @escaping (String?) -> Void) -> MobileMenuItem {
        var item = MobileMenuItem(category.categoryName, id: "category-\(category.id)",
                                  isSelected: isSelected, action: select)
        if allowsDefault {
            item.badge = isDefault ? "Default" : nil
            item.holdItems = [MobileMenuItem(isDefault ? "Remove Default" : "Set as Default",
                symbol: isDefault ? "house" : "house.fill", id: "default-category-\(category.id)") {
                changeDefault(isDefault ? nil : category.id)
            }]
        }
        return item
    }
}
