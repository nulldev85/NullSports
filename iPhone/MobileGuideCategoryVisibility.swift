import Foundation
import SwiftUI

struct MobileGuideCategoryVisibilityView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MobileGuideCategoryVisibility.storageKey) private var hiddenRaw = "{}"
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.categories.filter { query.isEmpty || $0.categoryName.localizedStandardContains(query) }) { category in
                        let source = library.categorySource(for: category.id)
                        Toggle(category.categoryName, isOn: Binding(get: {
                            !MobileGuideCategoryVisibility(hiddenRaw).isHidden(source.categoryID, provider: source.profileID)
                        }, set: { shown in
                            if let raw = MobileGuideCategoryVisibility(hiddenRaw).setting(!shown, category: source.categoryID, provider: source.profileID) { hiddenRaw = raw }
                        }))
                        .font(.inter(.body, .semibold)).tint(LineupStyle.highlight)
                        .listRowBackground(LineupPresentationStyle.card)
                        .accessibilityIdentifier("lineup.guide.category.\(category.id)")
                    }
                } footer: {
                    Text("Choose which categories appear in TV Guide. Favorites and Recently Watched stay available. This does not change Sports, Search or your provider’s channel list.")
                        .lineupSettingsFooter()
                }
                Section {
                    Button("Show All Categories") {
                        var raw = hiddenRaw
                        for category in library.categories {
                            let source = library.categorySource(for: category.id)
                            raw = MobileGuideCategoryVisibility(raw).setting(false, category: source.categoryID, provider: source.profileID) ?? raw
                        }
                        hiddenRaw = raw
                    }.foregroundStyle(LineupStyle.highlight)
                }.lineupSettingsRows()
            }
            .lineupSettingsList()
            .searchable(text: $query, prompt: "Find a category or provider")
            .navigationTitle("Categories").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LineupToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.buttonStyle(LineupBarButtonStyle(prominent: true))
                }
            }
        }
    }
}
