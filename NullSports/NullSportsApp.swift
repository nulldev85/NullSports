import SwiftUI
import UIKit

@main
struct NullSportsApp: App {
    @StateObject private var library = SportsLibrary()

    init() {
        #if os(tvOS)
        let purple = UIColor(NullSportsStyle.lightPurple)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(NullSportsStyle.background)
        appearance.selectionIndicatorTintColor = UIColor(NullSportsStyle.focused)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            for state in [item.normal, item.selected, item.disabled, item.focused] {
                state.iconColor = purple
                state.titleTextAttributes = [.foregroundColor: purple]
            }
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().unselectedItemTintColor = purple
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}
