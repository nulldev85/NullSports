// swift-tools-version:5.9
// ForgeCore is the platform-independent heart of the app: storage, models,
// timers and analytics. The iOS target compiles these same sources directly
// (see project.yml); this package exists so the core can be built and tested
// with `swift test` on macOS and Linux without a simulator.
import PackageDescription

let package = Package(
    name: "ForgeCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ForgeCore", targets: ["ForgeCore"]),
    ],
    targets: [
        // Linux has no SQLite3 Clang module; Apple platforms use the SDK's.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "ForgeCore",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/ForgeCore"
        ),
        .testTarget(
            name: "ForgeCoreTests",
            dependencies: ["ForgeCore"],
            path: "Tests/ForgeCoreTests"
        ),
    ]
)
