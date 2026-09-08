import SwiftUI
import UIKit

@main
struct NullSportsApp: App {
    @StateObject private var library = SportsLibrary()

    init() {
        let purple = UIColor(NullSportsStyle.lightPurple)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(NullSportsStyle.background)
        appearance.selectionIndicatorTintColor = purple
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            for state in [item.normal, item.selected, item.disabled, item.focused] {
                state.iconColor = purple
                state.titleTextAttributes = [.foregroundColor: purple]
            }
            item.focused.iconColor = UIColor(NullSportsStyle.background)
            item.focused.titleTextAttributes = [.foregroundColor: UIColor(NullSportsStyle.background)]
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().unselectedItemTintColor = purple
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}
