import XCTest
import SwiftUI
import UIKit
import Combine
@testable import LineupiOS

final class MobileOpenSubtitlesTests: XCTestCase {
    private func item(_ type: String = "Movie", imdb: String? = "tt0137523", season: Int? = nil, episode: Int? = nil) -> MediaItem {
        MediaItem(id: "source-scoped-id", name: "Title", type: type, overview: nil, productionYear: nil,
            primaryImageAspectRatio: nil, childCount: nil, indexNumber: episode, parentIndexNumber: season,
            providerIDs: imdb.map { ["Imdb": $0] })
    }
    private func movie() throws -> MobileSubtitleIdentity { try XCTUnwrap(MobileSubtitleIdentity(item: item())) }
    private func episode() throws -> MobileSubtitleIdentity {
        try XCTUnwrap(MobileSubtitleIdentity(item: item("Episode", imdb: "tt1480055", season: 1, episode: 1),
                           series: item("Series", imdb: "tt0944947")))
    }
    private var cue: String { "1\n00:00:01,000 --> 00:00:08,000\nFixture caption\n" }
    private func row(_ id: Int = 42, feature: String = #"{"feature_type":"Movie","imdb_id":137523}"#,
                     language: String = "en", extraFiles: String = "") -> String {
        #"{"attributes":{"language":""# + language + #"","release":"Fixture.1080p","hearing_impaired":false,"foreign_parts_only":false,"feature_details":"#
            + feature + #", "files":[{"file_id":"# + String(id) + #", "file_name":"fixture.srt","cd_number":1}"# + extraFiles + "]}}"
    }
    private func session(_ handler: @escaping SubtitleProtocol.Handler) -> URLSession {
        SubtitleProtocol.install(handler)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SubtitleProtocol.self]
        return URLSession(configuration: config)
    }

    func testExactIdentitySeparatesMoviesFromSeriesAndEpisodeIMDb() throws {
        let movie = try self.movie(), episode = try self.episode()
        XCTAssertEqual(movie.imdb, 137523)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: movie.query.map { ($0.name, $0.value!) }), ["imdb_id": "137523", "type": "movie"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: episode.query.map { ($0.name, $0.value!) }),
            ["parent_imdb_id": "944947", "type": "episode", "season_number": "1", "episode_number": "1"])
        XCTAssertNil(MobileSubtitleIdentity(item: item("Episode", season: 1, episode: 1)))
        XCTAssertNil(MobileSubtitleIdentity(item: item(imdb: nil)))
        XCTAssertNil(MobileSubtitleIdentity(item: item("Series")))
        XCTAssertNil(MobileSubtitleIdentity(item: item("Episode", season: 1, episode: 0), series: item("Series")))
    }

    func testResultsRejectWrongMovieEpisodeLanguageMalformedAndMultipartRecords() throws {
        let rows = [row(), row(), row(43, feature: #"{"feature_type":"Movie","imdb_id":550}"#), row(44, language: "fr"),
            row(45, extraFiles: #",{"file_id":46,"cd_number":2}"#), #"{"attributes":{}}"#]
        let results = try MobileOpenSubtitles.results(Data(("{\"data\":[" + rows.joined(separator: ",") + "]}").utf8), identity: movie(), language: "en")
        XCTAssertEqual(results.map(\.id), [42])
        let feature = #"{"feature_type":"Episode","imdb_id":1480055,"parent_imdb_id":944947,"season_number":1,"episode_number":1}"#
        let episodeRows = [row(1, feature: feature), row(2, feature: feature.replacingOccurrences(of: "\"episode_number\":1", with: "\"episode_number\":2")),
            row(3, feature: feature.replacingOccurrences(of: "\"parent_imdb_id\":944947", with: "\"parent_imdb_id\":1399"))]
        let exact = try MobileOpenSubtitles.results(Data(("{\"data\":[" + episodeRows.joined(separator: ",") + "]}").utf8), identity: episode(), language: "en")
        XCTAssertEqual(exact.map(\.id), [1])
    }

    func testRequestsUseTheConsumerKeyWithoutUserLoginAndNeverSendItToTheDownloadHost() async throws {
        let response = "{\"data\":[" + row() + "]}"
        let payload = cue
        let session = self.session { request in
            if request.url?.host == "www.opensubtitles.com" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Api-Key"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, [:], payload)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Api-Key"), "fixture-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Lineup v0.19.0")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url?.lastPathComponent == "download" {
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, [:], #"{"link":"https://www.opensubtitles.com/download/fixture.srt"}"#)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "imdb_id" }?.value, "137523")
            return (200, [:], response)
        }
        defer { session.invalidateAndCancel() }
        let api = MobileOpenSubtitles(key: "fixture-key", session: session)
        let identity = try movie()
        let rows = try await api.search(identity, language: "en")
        _ = try await api.search(identity, language: "en")
        XCTAssertEqual(SubtitleProtocol.count, 1)
        let selected = try XCTUnwrap(rows.first)
        let downloaded = try await api.download(selected)
        XCTAssertEqual(String(data: downloaded, encoding: .utf8), payload)
        _ = try await api.download(selected)
        XCTAssertEqual(SubtitleProtocol.count, 3, "Repeated selection uses the bounded memory cache, not another download allowance")
    }

    func testQuotaAndRateLimitsDoNotTriggerAutomaticRetriesOrAUserLogin() async throws {
        let session = self.session { _ in (429, ["Retry-After": "60"], "{}") }
        defer { session.invalidateAndCancel() }
        let api = MobileOpenSubtitles(key: "fixture-key", session: session)
        for _ in 0..<2 {
            do { _ = try await api.search(movie(), language: "en"); XCTFail("Rate limit must be reported") }
            catch { XCTAssertTrue(error is MobileSubtitleFailure) }
        }
        XCTAssertEqual(SubtitleProtocol.count, 1)
        SubtitleProtocol.install { _ in (406, [:], "{}") }
        let limited = MobileOpenSubtitles(key: "fixture-key", session: session)
        do {
            _ = try await limited.download(.init(id: 42, title: "Fixture", language: "en", hearingImpaired: false, foreignOnly: false))
            XCTFail("The download allowance must be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("allowance")) }
        XCTAssertEqual(SubtitleProtocol.count, 1)
    }

    func testOnlyOfficialHTTPSDownloadsAndUsableBoundedSubRipAreAccepted() throws {
        for value in ["https://www.opensubtitles.com/download/file.srt", "https://dl.opensubtitles.org/file"] {
            XCTAssertTrue(MobileOpenSubtitles.allowedDownload(try XCTUnwrap(URL(string: value))))
        }
        for value in ["http://www.opensubtitles.com/file", "https://opensubtitles.com.evil.invalid/file", "https://evilopensubtitles.com/file",
                      "https://user:pass@www.opensubtitles.com/file", "file:///tmp/file.srt", "https://www.opensubtitles.com:8080/file"] {
            XCTAssertFalse(MobileOpenSubtitles.allowedDownload(try XCTUnwrap(URL(string: value))))
        }
        XCTAssertNotNil(MobileOpenSubtitles.normalizedSubtitle(Data(cue.utf8)))
        let latin = cue.replacingOccurrences(of: "Fixture", with: "Café")
        XCTAssertEqual(String(data: try XCTUnwrap(MobileOpenSubtitles.normalizedSubtitle(try XCTUnwrap(latin.data(using: .isoLatin1)))), encoding: .utf8), latin)
        XCTAssertNil(MobileOpenSubtitles.normalizedSubtitle(Data("<html>Unavailable</html>".utf8)))
        XCTAssertNil(MobileOpenSubtitles.normalizedSubtitle(Data(repeating: 65, count: 5_000_001)))
        XCTAssertFalse(MobileOpenSubtitles.validLanguage("en&imdb_id=550"))
        XCTAssertTrue(MobileOpenSubtitles.validLanguage("pt-br"))
        var api = URLRequest(url: try XCTUnwrap(URL(string: "https://api.opensubtitles.com/api/v1/download")))
        api.setValue("fixture-key", forHTTPHeaderField: "Api-Key")
        let cdn = URLRequest(url: try XCTUnwrap(URL(string: "https://www.opensubtitles.com/download/file.srt")))
        XCTAssertNil(MobileOpenSubtitles.allowedRedirect(cdn, original: api), "An API credential cannot be forwarded to file hosting")
        XCTAssertNotNil(MobileOpenSubtitles.allowedRedirect(cdn, original: cdn))
        XCTAssertNotNil(MobileOpenSubtitles.allowedRedirect(api, original: api))
    }

    @MainActor
    func testNativeEditingStaysInTheSameFieldWhileActualFilteredResultsPublish() async throws {
        let model = MobileSubtitleResults()
        let rows = (0..<500).map { MobileOnlineSubtitle(id: $0, title: "Release.\($0).1080p", language: "en", hearingImpaired: false, foreignOnly: false) }
        model.replace(rows)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: SubtitleEditorHarness(model: model))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { model.cancel(); window.isHidden = true; previous?.makeKey() }
        let field = try XCTUnwrap(findField(host.view))
        let filtered = expectation(description: "native text edit publishes exact release results")
        let first = model.$visible.first { $0.map(\.id) == [499] }.sink { _ in filtered.fulfill() }
        defer { first.cancel() }
        for text in ["Release.1", "Release.49", "Release.499"] {
            field.text = text; field.sendActions(for: .editingChanged)
        }
        await fulfillment(of: [filtered], timeout: 5)
        host.view.layoutIfNeeded()
        XCTAssertTrue(findField(host.view) === field)
        XCTAssertEqual(field.text, "Release.499")
        let cleared = expectation(description: "native clear publishes all releases")
        let second = model.$visible.first { $0.count == 500 }.sink { _ in cleared.fulfill() }
        defer { second.cancel() }
        field.text = ""; field.sendActions(for: .editingChanged)
        await fulfillment(of: [cleared], timeout: 5)
        XCTAssertEqual(field.text, "")
        XCTAssertTrue(findField(host.view) === field)
    }

    @MainActor private func findField(_ view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        return view.subviews.lazy.compactMap { self.findField($0) }.first
    }
}

private struct SubtitleEditorHarness: View {
    @ObservedObject var model: MobileSubtitleResults
    var body: some View { VStack { MobileSubtitleSearchInput(results: model).frame(height: 44); Text("\(model.visible.count) releases") } }
}

private final class SubtitleProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (Int, [String: String], String)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func install(_ handler: @escaping Handler) { lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.requests += 1; Self.lock.unlock()
        let (status, headers, body) = handler?(request) ?? (500, [:], "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
