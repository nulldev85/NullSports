import Foundation
import SwiftUI

/// Saved with the provider's native ID, so combined Guide display IDs and
/// switching between providers cannot hide another service's categories.
struct MobileGuideCategoryVisibility {
    static let storageKey = "lineup.mobile.guide.hiddenCategories.v1"
    private var hidden: [String: Set<String>]

    init(_ raw: String) {
        hidden = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:]
    }
    func isHidden(_ category: String, provider: UUID?) -> Bool {
        guard let provider else { return false }
        return hidden[provider.uuidString]?.contains(category) == true
    }
    func hiddenDisplayIDs(in categories: [XtreamCategory], source: (String) -> (profileID: UUID?, categoryID: String)) -> Set<String> {
        Set(categories.compactMap { category in
            let origin = source(category.id)
            return isHidden(origin.categoryID, provider: origin.profileID) ? category.id : nil
        })
    }
    static func filtered(_ streams: [XtreamStream], hidden: Set<String>, personalList: Bool, gamePicker: Bool) -> [XtreamStream] {
        guard !gamePicker, !personalList, !hidden.isEmpty else { return streams }
        return streams.filter { !hidden.contains($0.categoryID ?? "") }
    }
    func setting(_ hide: Bool, category: String, provider: UUID?) -> String? {
        guard let provider, !category.isEmpty else { return nil }
        var copy = hidden
        if hide { copy[provider.uuidString, default: []].insert(category) }
        else { copy[provider.uuidString]?.remove(category) }
        if copy[provider.uuidString]?.isEmpty == true { copy[provider.uuidString] = nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(copy) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

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
