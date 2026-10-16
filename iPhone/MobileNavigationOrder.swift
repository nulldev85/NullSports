import SwiftUI

enum MobileNavigationOrder {
    static let storageKey = "lineup.appearance.tabOrder"
    static let defaultValue = "0,1,2,4,3"

    static func tabs(in value: String) -> [MobileNavigationTab] {
        var seen: Set<Int> = []
        let saved = value.split(separator: ",").compactMap { Int($0) }.compactMap(MobileNavigationTab.init(rawValue:))
        return (saved + MobileNavigationTab.allCases).filter { seen.insert($0.rawValue).inserted }
    }

    static func encode(_ tabs: [MobileNavigationTab]) -> String {
        self.tabs(in: tabs.map { String($0.rawValue) }.joined(separator: ","))
            .map { String($0.rawValue) }.joined(separator: ",")
    }
}

struct MobileNavigationOrderView: View {
    @AppStorage(MobileNavigationOrder.storageKey) private var savedOrder = MobileNavigationOrder.defaultValue

    var body: some View {
        List {
            Section {
                ForEach(MobileNavigationOrder.tabs(in: savedOrder)) { tab in
                    HStack(spacing: 14) {
                        tab.icon(selected: false).resizable().scaledToFit().frame(width: 26, height: 26)
                            .foregroundStyle(LineupStyle.text)
                        Text(tab.title).font(.inter(17, .medium)).foregroundStyle(LineupStyle.text)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("lineup.navigation.order.\(tab.rawValue)")
                }
                .onMove { offsets, destination in
                    var order = MobileNavigationOrder.tabs(in: savedOrder)
                    order.move(fromOffsets: offsets, toOffset: destination)
                    savedOrder = MobileNavigationOrder.encode(order)
                }
            } header: {
                Text("Navigation Bar").lineupSettingsHeader()
            } footer: {
                Text("Drag the handles to arrange your tabs. The order is saved automatically and applies to both navigation styles.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
            Section {
                Button("Restore Default Order") { savedOrder = MobileNavigationOrder.defaultValue }
                    .font(.inter(17, .medium)).foregroundStyle(LineupStyle.text)
                    .disabled(savedOrder == MobileNavigationOrder.defaultValue)
            }.lineupSettingsRows()
        }
        .lineupSettingsList()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tab Order").navigationBarTitleDisplayMode(.inline)
    }
}
