import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

@MainActor
final class StreamingServiceNavigationTests: XCTestCase {
    func testMoviesAndShowsPushThenBackUnwindsOnlyOnePageAndTheServiceCanBeReopened() async throws {
        let suite = "StreamingServiceNavigation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = MediaServerProfile(name: "Fixture", serverURL: "https://streaming-navigation.test", username: "viewer", userID: "viewer")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingNavigationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let media = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""), trackingKey: { nil },
            serverClientFactory: { _ in try JellyfinClient(serverURL: profile.serverURL, accessToken: "fixture", deviceID: "fixture", session: session) })
        let movie = MediaItem(id: "movie", name: "Fixture Movie", type: "Movie", overview: nil, productionYear: 2026,
            primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        let show = MediaItem(id: "show", name: "Fixture Show", type: "Series", overview: nil, productionYear: 2026,
            primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        let catalog = StreamingServiceTitles(movies: [.init(item: movie, popularRank: 1, latestRank: 1, year: 2026)],
            shows: [.init(item: show, popularRank: 1, latestRank: 1, year: 2026)])
        let state = StreamingNavigationRoot(), owner = StreamingServiceNavigation()
        let service = try XCTUnwrap(StreamingService.all.first)
        let root = StreamingNavigationFixture(state: state, owner: owner, service: service, catalog: catalog).environment(media)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); media.remove(profile) }
        try await wait { Self.navigation(window.rootViewController) != nil }
        let nav = try XCTUnwrap(Self.navigation(window.rootViewController))
        for throughAllServices in [false, true] {
            if throughAllServices {
                state.path.append(MediaLibrary.streamingRow)
                try await wait { nav.viewControllers.count == 2 }
            }
            let serviceDepth = throughAllServices ? 3 : 2
            state.path.append(service.item(titles: 2))
            try await wait { nav.viewControllers.count == serviceDepth }
            let serviceController = try XCTUnwrap(nav.topViewController)
            for title in [movie, show] {
                owner.select(title)
                try await wait { nav.viewControllers.count == serviceDepth + 1 }
                XCTAssertTrue(state.path.contains { $0.id == service.item(titles: 2).id }, "Opening a title must preserve the service's Library route")
                XCTAssertEqual(owner.item?.libraryKey, title.libraryKey)
                XCTAssertFalse(nav.topViewController === serviceController)
                state.temporarilyEmpty = true
                // Let the actual service view commit its empty refresh while
                // the detail is presented, rather than toggling twice in one pass.
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(nav.viewControllers.count, serviceDepth + 1)
                state.temporarilyEmpty = false
                nav.popViewController(animated: false)
                try await wait { nav.viewControllers.count == serviceDepth && owner.item == nil }
                XCTAssertTrue(nav.topViewController === serviceController)
            }
            nav.popViewController(animated: false)
            if throughAllServices {
                try await wait { nav.viewControllers.count == 2 }
                nav.popViewController(animated: false)
            }
            try await wait { state.path.isEmpty && nav.viewControllers.count == 1 }
        }
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        if !condition() {
            XCTFail("Navigation did not settle", file: file, line: line)
            throw NSError(domain: "StreamingServiceNavigationTests", code: 1)
        }
    }
    private static func navigation(_ root: UIViewController?) -> UINavigationController? {
        guard let root else { return nil }
        if let value = root as? UINavigationController { return value }
        return root.children.compactMap { navigation($0) }.first
    }
}

private final class StreamingNavigationRoot: ObservableObject {
    @Published var path: [MediaItem] = []
    @Published var temporarilyEmpty = false
}

private struct StreamingNavigationFixture: View {
    @ObservedObject var state: StreamingNavigationRoot
    let owner: StreamingServiceNavigation
    let service: StreamingService
    let catalog: StreamingServiceTitles
    var body: some View {
        NavigationStack(path: $state.path) {
            Text("Library").navigationTitle("Library")
                .navigationDestination(for: MediaItem.self) { item in
                    if StreamingService.service(for: item) != nil {
                        StreamingServiceScreen(service: service, navigation: owner, catalog: state.temporarilyEmpty ? StreamingServiceTitles() : catalog)
                    } else { MediaBrowseDestination(item: item) }
                }
        }
    }
}

private final class StreamingNavigationProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "streaming-navigation.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix("/items/movie") { body = #"{"Id":"movie","Name":"Fixture Movie","Type":"Movie"}"# }
        else if path.hasSuffix("/items/show") { body = #"{"Id":"show","Name":"Fixture Show","Type":"Series"}"# }
        else { body = #"{"Items":[]}"# }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
