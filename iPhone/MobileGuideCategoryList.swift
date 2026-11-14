import SwiftUI

/// The TV Guide tab's first page: what there is to watch, by category, as an
/// IPTV app lists it. Favorites, what was watched lately and every channel
/// come first, then the provider's own categories in its order. A row opens
/// that category's guide; the way back is the navigation bar's.
///
/// This replaced a dropdown over the guide, which hid the categories behind a
/// pill and made a long list of them hard to read.
struct MobileGuideCategoryList: View {
    let categories: [XtreamCategory]
    let hasFavorites: Bool
    let hasRecents: Bool
    /// The category saved as the one to open on, by its display ID.
    let defaultCategoryID: String?
    let allowsDefault: (XtreamCategory) -> Bool
    let open: (MobileGuideFilter) -> Void
    let setDefault: (XtreamCategory, Bool) -> Void
    let hide: (XtreamCategory) -> Void
    let manageCategories: () -> Void
    /// What the TV Guide's options menu held, now that the page has no bar.
    let viewModeTitle: String
    let isRefreshing: Bool
    let search: () -> Void
    let changeViewMode: () -> Void
    let refresh: () -> Void

    var body: some View {
        List {
            Section {
                row("Favorites", symbol: "star.fill", detail: hasFavorites ? nil : "None yet") { open(.favorites) }
                if hasRecents {
                    row("Recently Watched", symbol: "clock.arrow.circlepath") { open(.recents) }
                }
                row("All Channels", symbol: "tv") { open(.all) }
            }
            .lineupSettingsRows()

            Section {
                if categories.isEmpty {
                    Button(action: manageCategories) {
                        Text("Every category is hidden. Choose which to show.")
                            .font(.inter(.subheadline))
                            .foregroundStyle(LineupPresentationStyle.secondary)
                    }
                } else {
                    ForEach(categories) { category in
                        categoryRow(category)
                    }
                }
            } header: {
                Text("Categories").lineupSettingsHeader()
            } footer: {
                Text("Touch and hold a category to open the TV Guide on it, or to hide it.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()

            Section {
                row("Search Channels", symbol: "magnifyingglass", action: search)
                row("Layout", symbol: "rectangle.grid.1x2", detail: viewModeTitle, action: changeViewMode)
                    .accessibilityHint("Switches between the TV Guide grid and a list")
                row("Manage Categories", symbol: "eye.slash", action: manageCategories)
                Button(action: refresh) {
                    HStack(spacing: 12) {
                        LineupIconTile(symbol: "arrow.clockwise", size: 30)
                        Text(isRefreshing ? "Refreshing Guide…" : "Refresh Guide")
                            .font(.inter(.body, .semibold))
                            .foregroundStyle(LineupStyle.text)
                        Spacer(minLength: 8)
                        if isRefreshing { ProgressView() }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            } header: {
                Text("Guide").lineupSettingsHeader()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
    }

    private func row(_ title: String, symbol: String, detail: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(title, symbol: symbol, detail: detail)
        }
        .buttonStyle(.plain)
    }

    private func categoryRow(_ category: XtreamCategory) -> some View {
        let isDefault = defaultCategoryID == category.id
        return label(category.categoryName, symbol: "folder.fill", detail: isDefault ? "Opens first" : nil)
            .lineupHoldMenu(category.categoryName, symbol: "folder", press: .dim, items: {
                var items: [MobileMenuItem] = []
                if allowsDefault(category) {
                    items.append(MobileMenuItem(isDefault ? "Don't Open on This" : "Open TV Guide on This",
                                                symbol: isDefault ? "house" : "house.fill") {
                        setDefault(category, !isDefault)
                    })
                }
                items.append(MobileMenuItem("Hide Category", symbol: "eye.slash") { hide(category) })
                items.append(MobileMenuItem("Manage Categories", symbol: "list.bullet") { manageCategories() })
                return items
            }) {
                open(.category(category.id))
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the TV Guide on this category")
    }

    private func label(_ title: String, symbol: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            LineupIconTile(symbol: symbol, size: 30)
            Text(title)
                .font(.inter(.body, .semibold))
                .foregroundStyle(LineupStyle.text)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.inter(.subheadline))
                    .foregroundStyle(LineupPresentationStyle.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(LineupPanelStyle.listChevron)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
