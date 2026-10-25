import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

@MainActor
final class LibraryReliabilityTests: XCTestCase {
    private func fixture() throws -> (MediaLibrary, MediaServerProfile, UserDefaults, URLSession) {
        let profile = MediaServerProfile(name: "Test", serverURL: "https://library-review.test/base", username: "viewer", userID: "viewer")
        let defaults = UserDefaults(suiteName: "LibraryReliability." + UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryReliabilityProtocol.self]
        let session = URLSession(configuration: configuration)
        let library = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""),
            trackingKey: { nil }, serverClientFactory: { profile in
                try JellyfinClient(serverURL: profile.serverURL, accessToken: "fixture", deviceID: "test", session: session)
            })
        return (library, profile, defaults, session)
    }

    func testConcurrentDetailsShareARequestAndReturnToEveryCaller() async throws {
        let (library, profile, _, session) = try fixture()
        defer { session.invalidateAndCancel(); LibraryReliabilityProtocol.reset() }
        let received = expectation(description: "detail request received")
        LibraryReliabilityProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/base/users/viewer/items/film")
            received.fulfill()
            return nil // Held until both callers have entered details.
        }
        let item = MediaItem(id: "film", name: "Film", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        let first = Task { try await library.details(of: item) }
        let second = Task { try await library.details(of: item) }
        await fulfillment(of: [received], timeout: 3)
        await Task.yield()
        LibraryReliabilityProtocol.release(#"{"Id":"film","Name":"Full record","Type":"Movie"}"#)
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.name, "Full record")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.serverID, profile.id)
        _ = try await library.details(of: item)
        XCTAssertEqual(LibraryReliabilityProtocol.requestCount, 1)
    }

    func testRemovingServerRejectsItsLateDetail() async throws {
        let (library, profile, _, session) = try fixture()
        defer { session.invalidateAndCancel(); LibraryReliabilityProtocol.reset() }
        let received = expectation(description: "old request received")
        LibraryReliabilityProtocol.install { _ in received.fulfill(); return nil }
        let item = MediaItem(id: "film", name: "Film", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        let load = Task { try await library.details(of: item) }
        await fulfillment(of: [received], timeout: 3)
        library.remove(profile)
        LibraryReliabilityProtocol.release(#"{"Id":"film","Name":"Stale","Type":"Movie"}"#)
        do { _ = try await load.value; XCTFail("Removed account must not return a late title") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertTrue(library.catalogs.isEmpty)
    }

    func testShelfFailureRetainsSnapshotButSuccessfulEmptyShelfClearsIt() async throws {
        let (library, profile, _, session) = try fixture()
        defer { library.remove(profile); session.invalidateAndCancel(); LibraryReliabilityProtocol.reset() }
        for phase in 0...2 {
            LibraryReliabilityProtocol.install { request in
                let path = request.url!.path
                if path.hasSuffix("/views") { return #"{"Items":[{"Id":"movies","Name":"Movies","Type":"CollectionFolder"}]}"# }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if query.first(where: { $0.name == "ParentId" })?.value == "movies" {
                    if phase == 1 { throw URLError(.timedOut) }
                    return phase == 0 ? #"{"Items":[{"Id":"film","Name":"Loaded film","Type":"Movie"}]}"# : #"{"Items":[]}"#
                }
                if path.hasSuffix("/addons") { return "[]" }
                return #"{"Items":[],"TotalRecordCount":0}"#
            }
            await library.reload()
            XCTAssertEqual(library.state(of: profile).loadFailed, phase == 1)
            XCTAssertFalse(library.state(of: profile).isLoading)
            XCTAssertEqual(library.state(of: profile).catalogs.first?.items.map(\.id), phase == 2 ? [] : ["film"])
        }
    }

    func testInventoryCoalescesAndDiscardsRemovedSource() async throws {
        let (library, profile, _, session) = try fixture()
        defer { session.invalidateAndCancel(); LibraryReliabilityProtocol.reset() }
        let received = expectation(description: "one full inventory request")
        LibraryReliabilityProtocol.install { _ in received.fulfill(); return nil }
        let a = Task { await library.combinedInventory() }
        let b = Task { await library.combinedInventory() }
        await fulfillment(of: [received], timeout: 3)
        await Task.yield()
        library.remove(profile)
        LibraryReliabilityProtocol.release(#"{"Items":[{"Id":"old","Name":"Old","Type":"Movie"}]}"#)
        let first = await a.value, second = await b.value
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertNotNil(first.failure)
        XCTAssertNotNil(second.failure)
        XCTAssertEqual(LibraryReliabilityProtocol.requestCount, 1)
    }
}

private final class LibraryReliabilityProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> String?)?
    private static var held: [LibraryReliabilityProtocol] = []
    private static var count = 0
    private var stopped = false
    private var finished = false
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func install(_ value: @escaping (URLRequest) throws -> String?) {
        lock.lock(); defer { lock.unlock() }; handler = value
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; handler = nil; held = []; count = 0 }
    static func release(_ json: String) {
        lock.lock(); let waiting = held; held = []; lock.unlock()
        for entry in waiting { entry.finish(json) }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "library-review.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.held.append(self); let handler = Self.handler; Self.lock.unlock()
        do {
            if let json = try handler?(request) { finish(json) }
        } catch {
            Self.lock.lock(); Self.held.removeAll { $0 === self }; Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    private func finish(_ json: String) {
        Self.lock.lock(); let active = !stopped && !finished; finished = true
        Self.held.removeAll { $0 === self }; Self.lock.unlock()
        guard active else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
}
