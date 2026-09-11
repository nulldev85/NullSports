import SwiftUI
import UIKit

@main
struct LineupApp: App {
    @StateObject private var library = SportsLibrary()
    @StateObject private var media = MediaLibrary()

    init() {
        #if os(tvOS)
        applyLineupTabBarTheme()
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

#if os(tvOS)
func applyLineupTabBarTheme() {
    let accent = UIColor(LineupStyle.lightPurple)
    let appearance = UITabBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = UIColor(LineupStyle.background)
    appearance.selectionIndicatorTintColor = UIColor(LineupStyle.focused)
    for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
        for state in [item.normal, item.selected, item.disabled, item.focused] {
            state.iconColor = accent
            state.titleTextAttributes = [.foregroundColor: accent]
        }
    }
    UITabBar.appearance().standardAppearance = appearance
    UITabBar.appearance().scrollEdgeAppearance = appearance
    UITabBar.appearance().unselectedItemTintColor = accent
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .flatMap { window in allTabBars(in: window) }
        .forEach {
            $0.standardAppearance = appearance
            $0.scrollEdgeAppearance = appearance
            $0.unselectedItemTintColor = accent
        }
}

private func allTabBars(in view: UIView) -> [UITabBar] {
    (view as? UITabBar).map { [$0] } ?? view.subviews.flatMap { allTabBars(in: $0) }
}
#endif
