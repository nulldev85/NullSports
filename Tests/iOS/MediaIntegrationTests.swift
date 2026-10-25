import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class MediaIntegrationTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaIntegrationProtocol.self]
        return URLSession(configuration: configuration)
    }
    override func tearDown() { MediaIntegrationProtocol.reset(); super.tearDown() }

    func testSeerrPermissionFlagsKeepMovieSeriesAnd4KSeparate() throws {
        func user(_ permissions: Int) throws -> SeerrUser {
            try JSONDecoder().decode(SeerrUser.self, from: Data("{\"id\":7,\"permissions\":\(permissions)}".utf8))
        }
        XCTAssertTrue(try user(262144).canRequest(.movie))
        XCTAssertFalse(try user(262144).canRequest(.tv))
        XCTAssertFalse(try user(262144).canRequest(.movie, is4k: true))
        XCTAssertTrue(try user(262144 | 2048).canRequest(.movie, is4k: true))
        XCTAssertFalse(try user(32 | 4096).canRequest(.movie, is4k: true))
        XCTAssertTrue(try user(32 | 4096).canRequest(.tv, is4k: true))
        XCTAssertTrue(try user(2).managesRequests)
        XCTAssertFalse(try user(32).managesRequests)
    }

    func testSeerrCreatesExactSeasonRequestWithHeaderAuthAndNoQuotaBypass() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SeerrClient(address: "https://seerr-contract.test/prefix", credential: .init(apiKey: "fixture-key"), session: session)
        let submitted = expectation(description: "one request submission")
        MediaIntegrationProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "fixture-key")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-key"))
            switch request.url!.path {
            case "/prefix/api/v1/auth/me": return .json(#"{"id":7,"permissions":528384}"#)
            case "/prefix/api/v1/user/7/quota": return .json(#"{"tv":{"remaining":4,"restricted":false}}"#)
            case "/prefix/api/v1/tv/1399": return .json(#"{"id":1399,"name":"Example series","seasons":[{"id":1,"seasonNumber":1},{"id":2,"seasonNumber":2}],"mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status4k":5}]}}"#)
            case "/prefix/api/v1/request":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(body["mediaId"] as? Int, 1399)
                XCTAssertEqual(body["mediaType"] as? String, "tv")
                XCTAssertEqual(body["seasons"] as? [Int], [2], "Already available seasons must not be requested again")
                XCTAssertEqual(body["is4k"] as? Bool, true)
                XCTAssertNil(body["ignoreQuota"])
                XCTAssertNil(body["userId"])
                submitted.fulfill()
                return .json(#"{"id":12,"status":1,"is4k":true}"#, status: 201)
            default: throw URLError(.badURL)
            }
        }
        let result = try await client.request(id: 1399, kind: .tv, seasons: [1, 2, 999], is4k: true)
        XCTAssertEqual(result.id, 12)
        await fulfillment(of: [submitted], timeout: 2)
    }

    func testSeerrQuotaAndPermissionsPreventWritesAndLostRepliesAreNotRetried() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SeerrClient(address: "https://seerr-contract.test", credential: .init(apiKey: "fixture"), session: session)
        for mode in 0...2 {
            MediaIntegrationProtocol.install { request in
                if request.url!.path.hasSuffix("/auth/me") { return .json(mode == 0 ? #"{"id":7,"permissions":0}"# : #"{"id":7,"permissions":32}"#) }
                if request.url!.path.hasSuffix("/quota") { return .json(mode == 1 ? #"{"movie":{"restricted":true}}"# : #"{"movie":{"restricted":false}}"#) }
                if request.url!.path.hasSuffix("/movie/603") { return .json(#"{"id":603,"title":"The Matrix"}"#) }
                if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
                throw URLError(.badURL)
            }
            do { _ = try await client.request(id: 603, kind: .movie, seasons: [], is4k: false); XCTFail("Expected refusal") }
            catch { /* The specific client/server refusal is returned to the UI. */ }
            let writes = MediaIntegrationProtocol.requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(writes.count, mode == 2 ? 1 : 0)
        }
    }

    func testSeerrLocalSessionIsReturnedForKeychainAndReusedWithoutSharedCookies() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SeerrClient(address: "https://seerr-contract.test/base", credential: .init(), session: session)
        MediaIntegrationProtocol.install { request in
            if request.url!.path.hasSuffix("/auth/local") {
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(body["email"] as? String, "viewer@example.test")
                return .init(status: 200, json: #"{"id":7,"permissions":32}"#,
                    headers: ["Set-Cookie": "connect.sid=fixture-signed-session; Path=/base; HttpOnly; SameSite=Lax"])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "connect.sid=fixture-signed-session")
            return .json(#"{"id":7,"permissions":32}"#)
        }
        let (_, credential) = try await client.signIn(email: "viewer@example.test", password: "fixture-password")
        XCTAssertEqual(credential.cookie, "fixture-signed-session")
        XCTAssertNil(credential.apiKey)
        let restored = try SeerrClient(address: "https://seerr-contract.test/base", credential: credential, session: session)
        let account = try await restored.me()
        XCTAssertEqual(account.id, 7)
    }

    func testSiloOpaqueCatalogIDsCursorAndPrefixArePreservedWithoutStartingPlayback() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SiloClient(address: "https://silo-contract.test/proxy", credential: .init(accessToken: "fixture-key"), profileID: "profile:9007199254740999", deviceID: "fixture-device", session: session)
        MediaIntegrationProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile:9007199254740999")
            XCTAssertEqual(request.url!.path, "/proxy/api/v2/catalog")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "200")
            if let cursor = query.first(where: { $0.name == "cursor" })?.value {
                XCTAssertEqual(cursor, "opaque+/cursor==")
                return .json(#"{"items":[{"content_id":"9007199254740999","type":"series","title":"Series"}],"page":{"has_more":false}}"#)
            }
            return .json(#"{"items":[{"content_id":"movie:abc","type":"movie","title":"Movie","duration_seconds":7200,"position_seconds":600,"poster_url":"/api/v2/art/movie.jpg?sig=fixture"}],"page":{"has_more":true,"next_cursor":"opaque+/cursor=="}}"#)
        }
        let titles = try await client.allTitles(userID: "account", pageSize: 500, maxPages: 2)
        XCTAssertEqual(titles.map(\.id), ["movie:abc", "9007199254740999"])
        XCTAssertEqual(titles.first?.runTimeTicks, 72_000_000_000)
        XCTAssertEqual(titles.first?.userData?.playedPercentage ?? 0, 100 * 600 / 7200.0, accuracy: 0.001)
        XCTAssertEqual(URL(string: try XCTUnwrap(titles.first?.posterURL))?.path, "/proxy/api/v2/art/movie.jpg")
        XCTAssertTrue(MediaIntegrationProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testSiloProfilePINProofIsScopedAndVersionBrowsingDoesNotCreateASession() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SiloClient(address: "https://silo-contract.test/base", credential: .init(accessToken: "fixture-key"), profileID: nil, deviceID: "test", session: session)
        MediaIntegrationProtocol.install { request in
            if request.url!.path.hasSuffix("/verify-pin") {
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Id"))
                XCTAssertEqual(try MediaIntegrationProtocol.body(request)["pin"] as? String, "1234")
                return .json(#"{"valid":true,"profile_token":"fixture-proof","expires_at":null}"#)
            }
            if request.url!.path.hasSuffix("/profiles") { return .json(#"{"items":[{"id":"household:2","name":"Viewer","has_pin":true,"is_primary":false}]}"#) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "household:2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Token"), "fixture-proof")
            XCTAssertTrue(request.url!.path.hasSuffix("/versions"))
            return .json(#"{"items":[{"file_id":"9007199254740999","file_name":"Owned movie.mkv","resolution":"1080p","codec_video":"h264","codec_audio":"aac","container":"mkv","file_size":1024,"bitrate":8000,"duration":7200}]}"#)
        }
        let profiles = try await client.profiles()
        let profile = try XCTUnwrap(profiles.first)
        try await client.selectProfile(profile, pin: "1234")
        let result = try await client.playbackInfo(itemID: "movie:1")
        XCTAssertEqual(result.mediaSources.first?.siloFileID, "9007199254740999")
        XCTAssertEqual(result.mediaSources.first?.bitrate, 8_000_000, "Silo reports kilobits; the player displays bits per second")
        XCTAssertNil(result.mediaSources.first?.directURL)
        XCTAssertFalse(MediaIntegrationProtocol.requests.contains { $0.url!.path.contains("playback/start") })
        let credential = await client.credential()
        XCTAssertEqual(credential.profileToken, "fixture-proof")
    }

    @MainActor
    func testSiloRemuxRemoteSeekKeepsFullRuntimeAndSequencedServerProgress() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SiloClient(address: "https://silo-contract.test/base", credential: .init(accessToken: "fixture-key"), profileID: "profile:1", deviceID: "test", session: session)
        let replanned = expectation(description: "remote seek applied")
        MediaIntegrationProtocol.install { request in
            let path = request.url!.path
            if path.hasSuffix("/capabilities") {
                return .json(#"{"protocol_versions":[3],"features":["playback_plan_v3","seek_reanchor_v1"],"deliveries":["original_http","server_remux_hls","server_transcode_hls"],"installation_id":"installation:1","state":"available","allowed":true}"#)
            }
            let body = try MediaIntegrationProtocol.body(request)
            if path.hasSuffix("/start") {
                XCTAssertEqual(body["file_id"] as? String, "file:42")
                XCTAssertEqual(body["profile_id"] as? String, "profile:1")
                XCTAssertEqual(body["start_position"] as? Double, 600)
                XCTAssertEqual(body["progress_persistence"] as? String, "server")
                return .json(Self.plan(offset: 598, playerStart: 2, planID: "plan:1"), status: 201)
            }
            if path.hasSuffix("/replan") {
                XCTAssertEqual(body["operation"] as? String, "seek_reanchor")
                XCTAssertEqual(body["position_seconds"] as? Double, 720)
                XCTAssertEqual(body["failed_plan_id"] as? String, "plan:1")
                return .json(Self.plan(offset: 719, playerStart: 1, planID: "plan:2"))
            }
            let sequence = try XCTUnwrap(body["sequence"] as? Int)
            XCTAssertEqual(body["installation_id"] as? String, "installation:1")
            if path.hasSuffix("/progress") {
                XCTAssertEqual(body["position"] as? Double, 723)
                return .json("{\"outcome\":\"applied\",\"accepted\":{\"sequence\":\(sequence)}}")
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(body["position"] as? Double, 725)
            XCTAssertNotNil(body["stop_id"])
            return .json("{\"outcome\":\"stopped\",\"accepted\":{\"sequence\":\(sequence)}}")
        }
        let playback = SiloPlaybackSession()
        let opened = try await playback.open(client: client, fileID: "file:42", position: 600)
        XCTAssertEqual(opened.url.path, "/base/api/v2/playback/transcode/session:1/master.m3u8")
        XCTAssertEqual(opened.duration, 3600)
        XCTAssertEqual(playback.sourcePosition(playerTime: 4), 602)
        playback.assetChanged = { asset in XCTAssertEqual(asset.duration, 3600); replanned.fulfill() }
        playback.seek(to: 720)
        await fulfillment(of: [replanned], timeout: 3)
        XCTAssertEqual(playback.sourcePosition(playerTime: 4), 723)
        playback.sample(position: 723, paused: true)
        playback.finalPosition(725)
        await playback.stop()
        let numbers = try MediaIntegrationProtocol.requests.filter { $0.url!.path.hasSuffix("/progress") || $0.httpMethod == "DELETE" }
            .map { request in
                let body = try MediaIntegrationProtocol.body(request)
                return try XCTUnwrap(body["sequence"] as? Int)
            }
        XCTAssertEqual(numbers, [1, 2])
    }

    func testIntegrationURLsRejectEmbeddedCredentialsAndEncodeOpaquePathComponents() throws {
        XCTAssertThrowsError(try MediaIntegrationHTTP(address: "https://user:password@example.test"))
        XCTAssertThrowsError(try MediaIntegrationHTTP(address: "https://example.test?key=value"))
        let http = try MediaIntegrationHTTP(address: "https://example.test/base/")
        let url = try http.url(["api", "v2", "catalog", "items", "opaque/a?b#c"])
        XCTAssertTrue(url.absoluteString.contains("opaque%2Fa%3Fb%23c"))
        XCTAssertEqual(http.resolvedURL("/api/v2/stream/one")?.path, "/base/api/v2/stream/one")
        XCTAssertEqual(http.resolvedURL("/base/api/v2/stream/one")?.path, "/base/api/v2/stream/one")
    }

    func testSeerrMediaServerAndPlexSignInsUseTheConfiguredSeerrSession() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        for method in [SeerrSignInMethod.jellyfin, .emby, .plex] {
            let client = try SeerrClient(address: "https://seerr-contract.test/base", credential: .init(), session: session)
            MediaIntegrationProtocol.install { request in
                let body = try MediaIntegrationProtocol.body(request)
                if method == .plex {
                    XCTAssertEqual(request.url!.path, "/base/api/v1/auth/plex")
                    XCTAssertEqual(body["authToken"] as? String, "fixture-plex-token")
                } else {
                    XCTAssertEqual(request.url!.path, "/base/api/v1/auth/jellyfin")
                    XCTAssertEqual(body["serverType"] as? Int, method == .emby ? 3 : 2)
                    XCTAssertEqual(body["username"] as? String, "viewer")
                    XCTAssertNil(body["hostname"], "The client must not reconfigure Seerr's linked media server")
                }
                return .init(status: 200, json: #"{"id":7,"permissions":32}"#,
                    headers: ["Set-Cookie": "connect.sid=fixture-session; Path=/base; HttpOnly"])
            }
            let signedIn: (SeerrUser, SeerrCredential)
            if method == .plex { signedIn = try await client.signInPlex(token: "fixture-plex-token") }
            else { signedIn = try await client.signInMediaServer(username: "viewer", password: "fixture", emby: method == .emby) }
            XCTAssertEqual(signedIn.0.id, 7)
            XCTAssertEqual(signedIn.1.cookie, "fixture-session")
        }
    }

    func testSeerrAdvancedOptionsAreCheckedAgainstLiveServerProfiles() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SeerrClient(address: "https://seerr-contract.test", credential: .init(apiKey: "fixture"), session: session)
        MediaIntegrationProtocol.install { request in
            switch request.url!.path {
            case "/api/v1/auth/me": return .json(#"{"id":7,"permissions":8224}"#)
            case "/api/v1/user/7/quota": return .json(#"{"movie":{"restricted":false}}"#)
            case "/api/v1/movie/603": return .json(#"{"id":603,"title":"The Matrix"}"#)
            case "/api/v1/service/radarr": return .json(#"[{"id":0,"name":"Movies","is4k":false}]"#)
            case "/api/v1/service/radarr/0": return .json(#"{"server":{"id":0,"name":"Movies","is4k":false},"profiles":[{"id":101,"name":"1080p"}],"rootFolders":[{"id":2,"path":"/media/movies"}]}"#)
            case "/api/v1/request":
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(body["serverId"] as? Int, 0)
                XCTAssertEqual(body["profileId"] as? Int, 101)
                XCTAssertEqual(body["rootFolder"] as? String, "/media/movies")
                XCTAssertNil(body["ignoreQuota"])
                return .json(#"{"id":12,"status":1}"#, status: 201)
            default: throw URLError(.badURL)
            }
        }
        let options = SeerrRequestOptions(serverID: 0, serverName: "Movies", profileID: 101, rootFolder: "/media/movies")
        _ = try await client.request(id: 603, kind: .movie, seasons: [], is4k: false, options: options)
        var invalid = options; invalid.rootFolder = "/not-configured"
        do { _ = try await client.request(id: 603, kind: .movie, seasons: [], is4k: false, options: invalid); XCTFail("Unknown folders must be refused") }
        catch { }
        XCTAssertEqual(MediaIntegrationProtocol.requests.filter { $0.url!.path == "/api/v1/request" }.count, 1)
        await client.signOut()
        do { _ = try await client.requests(); XCTFail("Disconnected clients must not make new account requests") }
        catch { }
    }

    @MainActor
    func testSiloServerWatchStateAndFavoritesMergeWithoutReplacingLocalTracking() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let defaults = UserDefaults(suiteName: "SiloServerState." + UUID().uuidString)!
        let profile = MediaServerProfile(name: "Silo", serverURL: "https://silo-contract.test", username: "viewer", userID: "account:1", software: .silo, siloProfileID: "profile:1")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        let item = MediaItem(id: "film:1", name: "Film", type: "Movie", overview: nil, productionYear: 2026,
            primaryImageAspectRatio: nil, childCount: nil, runTimeTicks: 36_000_000_000, serverID: profile.id)
        let local = LocalMediaPlayback(profileID: profile.id, item: item, position: 300, duration: 3600,
            updatedAt: Date().addingTimeInterval(-120), completed: false)
        let saved = try JSONEncoder().encode([local])
        defaults.set(saved, forKey: "Lineup.localMediaPlayback.v1")
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let client = try SiloClient(address: profile.serverURL, credential: .init(accessToken: "fixture"),
            profileID: profile.siloProfileID, deviceID: "fixture", session: session)
        let library = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""),
            trackingKey: { nil }, serverClientFactory: { _ in client })
        defer { library.remove(profile) }
        MediaIntegrationProtocol.install { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.first(where: { $0.name == "source" })?.value == "history" {
                return .json("{\"items\":[{\"content_id\":\"film:1\",\"type\":\"movie\",\"title\":\"Film\",\"duration_seconds\":3600,\"position_seconds\":1200,\"progress_updated_at\":\"\(timestamp)\",\"user_state\":{\"played\":false}}]}")
            }
            return .json(#"{"items":[{"content_id":"film:1","type":"movie","title":"Film","user_state":{"is_favorite":true}}]}"#)
        }
        await library.refreshNativeSiloState(for: profile)
        XCTAssertEqual(library.resumePosition(for: item), 1200)
        XCTAssertEqual(library.continueWatching.first?.item.serverID, profile.id)
        XCTAssertEqual(library.favoriteMedia.map(\.id), ["film:1"])
        XCTAssertEqual(defaults.data(forKey: "Lineup.localMediaPlayback.v1"), saved, "Server state is cached separately from local history")
        MediaIntegrationProtocol.install { _ in throw URLError(.timedOut) }
        await library.refreshNativeSiloState(for: profile)
        XCTAssertEqual(library.resumePosition(for: item), 1200, "A failed refresh must preserve known server state")
        library.setLocalFavorite(false, for: item)
        XCTAssertTrue(library.favoriteMedia.isEmpty)
        let playback = UUID()
        library.beginPlaybackSession(for: item, id: playback)
        library.trackPlayback(of: item, position: 1220, duration: 3600, sessionID: playback)
        XCTAssertEqual(library.resumePosition(for: item), 1220, "Actual foreground progress wins over an older cloud answer")
        library.endPlaybackSession(playback)
        library.setLocalTrackingEnabled(false)
        library.setMDBListTrackingEnabled(false)
        let localBytes = defaults.data(forKey: "Lineup.localMediaPlayback.v1")
        MediaIntegrationProtocol.install { request in
            if request.url!.path.contains("/watched/") {
                XCTAssertTrue(["POST", "DELETE"].contains(request.httpMethod ?? ""))
                return .json("{}")
            }
            return .json(#"{"items":[]}"#)
        }
        await library.setEpisodePlayedAndAdvance(true, for: item)
        XCTAssertTrue(library.isWatched(item), "Native watched actions work with both Lineup trackers disabled")
        await library.setEpisodePlayedAndAdvance(false, for: item)
        XCTAssertFalse(library.isWatched(item))
        await library.refreshNativeSiloState(for: profile)
        XCTAssertFalse(library.isWatched(item), "An acknowledged unwatched action survives omission from server history")
        XCTAssertEqual(defaults.data(forKey: "Lineup.localMediaPlayback.v1"), localBytes,
            "Native server actions must not write disabled local history")
        XCTAssertEqual(MediaIntegrationProtocol.requests.filter { $0.url!.path.contains("/watched/") }.count, 2)
    }

    func testSourceSubtitleTimelineClipsPastCuesAndRebasesFromOriginalBytes() throws {
        let source = Data("1\n00:09:58,000 --> 00:10:01,000\nCrosses the cut\n\n2\n00:10:02,000 --> 00:10:04,000\nLater caption\n".utf8)
        let first = String(decoding: try SubtitleSourceTimeline.rebase(source, offset: 600), as: UTF8.self)
        XCTAssertTrue(first.contains("00:00:00,000 --> 00:00:01,000"))
        XCTAssertTrue(first.contains("00:00:02,000 --> 00:00:04,000"))
        let next = String(decoding: try SubtitleSourceTimeline.rebase(source, offset: 602), as: UTF8.self)
        XCTAssertFalse(next.contains("Crosses the cut"))
        XCTAssertTrue(next.contains("00:00:00,000 --> 00:00:02,000"))
        XCTAssertEqual(try SubtitleSourceTimeline.rebase(source, offset: 0), source)
        XCTAssertThrowsError(try SubtitleSourceTimeline.rebase(source, offset: .nan))
    }

    @MainActor
    func testExplicitSiloRetryStartsFreshAttemptAndPreservesSourcePositionAndCaptions() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SiloClient(address: "https://silo-contract.test/base", credential: .init(accessToken: "fixture-key"),
            profileID: "profile:1", deviceID: "test", session: session)
        let reopened = expectation(description: "fresh playback attempt applied")
        MediaIntegrationProtocol.install { request in
            let path = request.url!.path
            if path.hasSuffix("/capabilities") {
                return .json(#"{"protocol_versions":[3],"features":["playback_plan_v3","seek_reanchor_v1"],"deliveries":["original_http","server_remux_hls"],"installation_id":"installation:1","state":"available","allowed":true}"#)
            }
            let body = try MediaIntegrationProtocol.body(request)
            if path.hasSuffix("/start") {
                let starts = MediaIntegrationProtocol.requests.filter { $0.url!.path.hasSuffix("/start") }
                XCTAssertEqual(body["start_position"] as? Double, starts.count == 1 ? 600 : 625)
                return .json(Self.plan(offset: starts.count == 1 ? 598 : 624, playerStart: starts.count == 1 ? 2 : 1,
                    planID: "plan:\(starts.count)"), status: 201)
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            return .json(#"{"outcome":"stopped"}"#)
        }
        let playback = SiloPlaybackSession()
        _ = try await playback.open(client: client, fileID: "file:42", position: 600)
        playback.finalPosition(625)
        let captions = Data("1\n00:10:30,000 --> 00:10:32,000\nCaption\n".utf8)
        playback.rememberSubtitle(captions, title: "English", language: "en")
        playback.assetChanged = { asset in
            XCTAssertEqual(asset.lease.timelineOffset + asset.lease.playerStart, 625)
            XCTAssertEqual(playback.sidecars.first?.data, captions)
            reopened.fulfill()
        }
        playback.retryFailed = { message in XCTFail(message); reopened.fulfill() }
        playback.retry(); playback.retry()
        await fulfillment(of: [reopened], timeout: 5)
        let starts = MediaIntegrationProtocol.requests.filter { $0.url!.path.hasSuffix("/start") }
        XCTAssertEqual(starts.count, 2, "Repeated Retry during planning must not create duplicate sessions")
        let first = try MediaIntegrationProtocol.body(starts[0])["playback_attempt_id"] as? String
        let second = try MediaIntegrationProtocol.body(starts[1])["playback_attempt_id"] as? String
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(MediaIntegrationProtocol.requests.filter { $0.httpMethod == "DELETE" }.count, 1)
        playback.retryAllowed = { false }
        playback.retry()
        await playback.stop()
        playback.retry()
        XCTAssertEqual(MediaIntegrationProtocol.requests.filter { $0.url!.path.hasSuffix("/start") }.count, 2,
            "A closed or detached player cannot start another server session")
    }

    private static func plan(offset: Double, playerStart: Double, planID: String) -> String {
        """
        {"protocol_version":3,"outcome":"playable","session_id":"session:1","playback_plan":{
        "plan_id":"\(planID)","plan_attempt_key":"v3:fixture","delivery":"server_remux_hls",
        "stream":{"url":"/api/v2/playback/transcode/session:1/master.m3u8","headers":{},"header_refresh":"none"},
        "timeline":{"source_start_seconds":\(offset + playerStart),"player_start_seconds":\(playerStart),"timeline_offset_seconds":\(offset),"can_seek_anywhere":false},
        "selected_tracks":{},"source":{"duration_seconds":3600}}}
        """
    }
}

private final class MediaIntegrationProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let json: String
        var headers: [String: String] = [:]
        static func json(_ value: String, status: Int = 200) -> Self { .init(status: status, json: value) }
    }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Reply)?
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func install(_ value: @escaping (URLRequest) throws -> Reply) {
        lock.lock(); defer { lock.unlock() }; handler = value; recorded = []
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; handler = nil; recorded = [] }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("-contract.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, captured.httpBodyStream != nil {
                captured.httpBody = try JSONSerialization.data(withJSONObject: Self.body(request))
            }
            Self.lock.lock(); let handler = Self.handler; Self.recorded.append(captured); Self.lock.unlock()
            guard let reply = try handler?(captured) else { throw URLError(.badURL) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
                httpVersion: nil, headerFields: reply.headers.merging(["Content-Type": "application/json"], uniquingKeysWith: { left, _ in left }))!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
