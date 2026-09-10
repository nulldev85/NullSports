import SwiftUI
import UIKit

@main
struct LineupApp: App {
    @StateObject private var library = SportsLibrary()
    @StateObject private var media = MediaLibrary()

    init() {
        #if os(tvOS)
        let purple = UIColor(LineupStyle.lightPurple)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(LineupStyle.background)
        appearance.selectionIndicatorTintColor = UIColor(LineupStyle.focused)
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
                .environmentObject(media)
                .preferredColorScheme(.dark)
        }
    }
}
