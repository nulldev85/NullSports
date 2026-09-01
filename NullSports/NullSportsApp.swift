import SwiftUI

@main
struct NullSportsApp: App {
    @StateObject private var library = SportsLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}

