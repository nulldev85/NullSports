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

    #if os(iOS)
    @MainActor
    func testAIOContinueWatchingTracksResumeAcrossRefreshFailureAndRelaunch() async throws {
        let suite = "AIOResume.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alex = MediaServerProfile(name: "Home", serverURL: "https://aio-contract.test/jellyfin/u/home",
                                      username: "Alex", userID: "a")
        let sam = MediaServerProfile(name: "Home", serverURL: alex.serverURL, username: "Sam", userID: "b")
        defaults.set(try JSONEncoder().encode([alex, sam]), forKey: "NullSports.mediaServers")
        let network = session()
        defer { network.invalidateAndCancel() }
        func library() -> MediaLibrary {
            MediaLibrary(defaults: defaults, trackingKey: { nil }, serverClientFactory: { profile in
                try JellyfinClient(serverURL: profile.serverURL, accessToken: "token-" + profile.userID, deviceID: "fixture", session: network)
            })
        }
        func respond(_ ids: [String], for userID: String = "a", status: Int = 200) throws {
            let items = ids.map { id in
                ["Id": id, "Name": id, "Type": "Movie", "RunTimeTicks": 36_000_000_000,
                 "UserData": ["PlaybackPositionTicks": 600_000_000]] as [String: Any]
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["Items": items]), as: UTF8.self)
            MediaIntegrationProtocol.install { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "token-" + userID)
                switch request.url?.path.lowercased() {
                case "/jellyfin/u/home/system/info/public": return .json(#"{"aiostreams":{"features":{"users":1}}}"#)
                case "/jellyfin/u/home/users/\(userID)/items/resume": return .json(json, status: status)
                case "/jellyfin/u/home/users/\(userID)/items": return .json(#"{"Items":[]}"#)
                default: XCTFail("Unexpected AIO watch-state request: \(request.url?.path ?? "")"); return .json("{}", status: 404)
                }
            }
        }
        let media = library()
        let old = MediaItem(id: "old", name: "Old Show", type: "Episode", overview: nil,
                            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil).servedBy(alex.id)
        media.rememberNextUp(old)
        XCTAssertEqual(media.continueWatching.map(\.item.id), ["old"])

        try respond(["newer", "older"])
        await media.importServerProgress(for: alex)
        XCTAssertEqual(media.continueWatching.map(\.item.id), ["newer", "older"], "Undated titles keep server order")
        try respond(["older"])
        await media.importServerProgress(for: alex)
        XCTAssertEqual(media.continueWatching.map(\.item.id), ["older"])
        XCTAssertEqual(media.resumePosition(for: try XCTUnwrap(media.continueWatching.first?.item)), 60)

        // Reopen with a different saved household account on the same server.
        defaults.set([sam.id.uuidString], forKey: "Lineup.preferredJellyfinAccounts.v1")
        let other = library()
        try respond(["sam-film"], for: sam.userID)
        await other.importServerProgress(for: sam)
        XCTAssertEqual(other.continueWatching.map(\.item.id), ["sam-film"])
        defaults.set([alex.id.uuidString], forKey: "Lineup.preferredJellyfinAccounts.v1")
        let restored = library()
        XCTAssertEqual(restored.continueWatching.map(\.item.id), ["older"])
        try respond([], status: 503)
        await restored.importServerProgress(for: alex)
        XCTAssertEqual(restored.continueWatching.map(\.item.id), ["older"])
        try respond([])
        await restored.importServerProgress(for: alex)
        XCTAssertTrue(restored.continueWatching.isEmpty)
        XCTAssertTrue(library().continueWatching.isEmpty)
        XCTAssertNotNil(restored.localPlaybackRecord(for: old), "Filtering the shelf must preserve saved tracking data")
        defaults.set([sam.id.uuidString], forKey: "Lineup.preferredJellyfinAccounts.v1")
        XCTAssertEqual(library().continueWatching.map(\.item.id), ["sam-film"])
    }
    #endif

    @MainActor
    func testAIOProfilePickerUsesSessionAndRejectsAnotherUsersToken() async throws {
        let suite = "AIOProfilePicker.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = MediaServerProfile(name: "Home", serverURL: "https://aio-contract.test/jellyfin/u/home",
                                        username: "Alex", userID: "a")
        defaults.set(try JSONEncoder().encode([source]), forKey: "NullSports.mediaServers")
        let network = session()
        defer { network.invalidateAndCancel() }
        MediaIntegrationProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "token-a")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/jellyfin/u/home/system/info/public"):
                return .json(#"{"aiostreams":{"features":{"users":1}}}"#)
            case ("GET", "/jellyfin/u/home/AIOStreams/Users"):
                return .json(#"[{"user":{"Id":"b","Name":"Sam","PrimaryImageTag":"picture-v2"},"needs":"password-pin"},{"user":{"Id":"c","Name":"Lee"},"needs":null}]"#)
            case ("POST", "/jellyfin/u/home/AIOStreams/Token"):
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(body["UserId"] as? String, "b")
                XCTAssertEqual(body["Pw"] as? String, "fixture/1234")
                return .json(#"{"User":{"Id":"c","Name":"Lee"},"AccessToken":"wrong-user-token"}"#)
            default: XCTFail("Unexpected profile request"); return .json("{}", status: 404)
            }
        }
        let media = MediaLibrary(defaults: defaults, trackingKey: { nil }, serverClientFactory: { profile in
            try JellyfinClient(serverURL: profile.serverURL, accessToken: "token-a", deviceID: "fixture", session: network)
        })
        let choices = try await media.profileChoices(on: source)
        XCTAssertEqual(choices.map(\.name), ["Sam", "Lee"])
        let sam = try XCTUnwrap(choices.first)
        let avatar = try XCTUnwrap(sam.avatarURL)
        XCTAssertEqual(avatar.path, "/jellyfin/u/home/Users/b/Images/Primary")
        XCTAssertTrue(URLComponents(url: avatar, resolvingAgainstBaseURL: false)?.queryItems?.contains(
            URLQueryItem(name: "tag", value: "picture-v2")) == true)
        XCTAssertNil(choices.last?.avatarURL)
        guard case .household(.passwordPin) = sam.access else { return XCTFail("Expected password and PIN") }
        do {
            try await media.useProfile(sam, from: source, secret: "fixture/1234")
            XCTFail("Another user's token must not activate a profile")
        } catch MediaIntegrationError.unavailable { }
        XCTAssertEqual(media.profiles, [source])
        XCTAssertEqual(media.savedProfiles, [source])
    }

    @MainActor
    func testSavedProfileUsesCurrentJellyfinAvatarWithoutDuplicatingPublicUser() async throws {
        let suite = "ProfilePhotos.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = MediaServerProfile(name: "Home", serverURL: "https://jellyfin-contract.test/mount",
                                       username: "Alex", userID: "a")
        saved.primaryImageTag = "old"
        defaults.set(try JSONEncoder().encode([saved]), forKey: "NullSports.mediaServers")
        let network = session()
        defer { network.invalidateAndCancel() }
        let client = try JellyfinClient(serverURL: saved.serverURL, deviceID: "fixture", session: network)
        let media = MediaLibrary(defaults: defaults, trackingKey: { nil }, serverClientFactory: { _ in client })
        MediaIntegrationProtocol.install { request in
            if request.url?.path == "/mount/system/info/public" { return .json(#"{"Version":"10.10.0"}"#) }
            XCTAssertEqual(request.url?.path, "/mount/Users/Public")
            return .json(#"[{"Id":"A","Name":"Alex","PrimaryImageTag":"new"},{"Id":"b","Name":"Sam"}]"#)
        }
        let choices = try await media.profileChoices(on: saved)
        XCTAssertEqual(choices.map(\.name), ["Alex", "Sam"])
        let alex = try XCTUnwrap(choices.first)
        guard case .saved = alex.access else { return XCTFail("Saved users should still switch without signing in") }
        let url = try XCTUnwrap(alex.avatarURL)
        XCTAssertEqual(url.path, "/mount/UserImage")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "tag", value: "new")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "userId", value: "a")))
        XCTAssertNil(choices.last?.avatarURL)
        MediaIntegrationProtocol.install { request in
            if request.url?.path == "/mount/system/info/public" { return .json(#"{"Version":"10.10.0"}"#) }
            return .json(#"[{"Id":"a","Name":"Alex"}]"#)
        }
        let afterRemoval = try await media.profileChoices(on: saved)
        XCTAssertNil(try XCTUnwrap(afterRemoval.first).avatarURL)
    }

    func testJellyfinPickerAndQuickConnectUseTheMountedServerAndApprovedUser() async throws {
        let network = session()
        defer { network.invalidateAndCancel() }
        let client = try JellyfinClient(serverURL: "https://jellyfin-contract.test/jellyfin/u/home",
                                        deviceID: "fixture", session: network)
        MediaIntegrationProtocol.install { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("DeviceId=\"fixture\"") == true)
            switch (request.httpMethod, url.path) {
            case ("GET", "/jellyfin/u/home/Users/Public"):
                return .json(#"[{"Id":"a","Name":"Alex"},{"Id":"b","Name":"Sam"}]"#)
            case ("GET", "/jellyfin/u/home/QuickConnect/Enabled"): return .json("true")
            case ("POST", "/jellyfin/u/home/QuickConnect/Initiate"):
                return .json(#"{"Code":"012345","Secret":"private/token"}"#)
            case ("GET", "/jellyfin/u/home/QuickConnect/Connect"):
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "secret", value: "private/token")])
                let polls = MediaIntegrationProtocol.requests.filter { $0.url?.lastPathComponent == "Connect" }
                return .json(polls.count == 1 ? #"{"Authenticated":false}"# : #"{"Authenticated":true}"#)
            case ("POST", "/jellyfin/u/home/Users/AuthenticateWithQuickConnect"):
                XCTAssertEqual(try MediaIntegrationProtocol.body(request)["Secret"] as? String, "private/token")
                return .json(#"{"User":{"Id":"b","Name":"Sam"},"ServerId":"home","AccessToken":"session-b"}"#)
            default: XCTFail("Unexpected request"); return .json("{}", status: 404)
            }
        }
        let users = try await client.publicUsers()
        XCTAssertEqual(users.map(\.name), ["Alex", "Sam"])
        let challenge = try await client.beginQuickConnect()
        XCTAssertEqual(challenge.code, "012345")
        let pending = try await client.quickConnectAuthentication(secret: challenge.secret)
        XCTAssertNil(pending)
        XCTAssertFalse(MediaIntegrationProtocol.requests.contains { $0.url?.lastPathComponent == "AuthenticateWithQuickConnect" })
        let approved = try await client.quickConnectAuthentication(secret: challenge.secret)
        XCTAssertEqual(approved?.user.id, "b")
        XCTAssertEqual(approved?.accessToken, "session-b")
        XCTAssertEqual(approved?.serverID, "home")
    }

    func testDisabledOrExpiredQuickConnectDoesNotExchangeASecret() async throws {
        let network = session()
        defer { network.invalidateAndCancel() }
        let client = try JellyfinClient(serverURL: "https://home-contract.test", deviceID: "fixture", session: network)
        MediaIntegrationProtocol.install { request in
            switch request.url?.lastPathComponent {
            case "Enabled": return .json("false")
            case "Connect": return .json("{}", status: 404)
            default: XCTFail("Unexpected sign-in request"); return .json("{}", status: 404)
            }
        }
        do {
            _ = try await client.beginQuickConnect()
            XCTFail("A disabled server must not issue a challenge")
        } catch MediaIntegrationError.unavailable(let reason) {
            XCTAssertTrue(reason.contains("disabled"))
        }
        do {
            _ = try await client.quickConnectAuthentication(secret: "expired")
            XCTFail("An expired code requires a new challenge")
        } catch MediaIntegrationError.unavailable(let reason) {
            XCTAssertTrue(reason.contains("expired"))
        }
    }

    @MainActor
    func testSavedJellyfinAccountsKeepIndependentPositionsAcrossSwitchAndRelaunch() throws {
        let suite = "JellyfinHousehold.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MediaServerProfile(name: "Home", serverURL: "https://home.invalid/jellyfin/u/home",
                                      username: "Alex", userID: "a")
        var second = MediaServerProfile(name: "Home", serverURL: "https://home.invalid/jellyfin/p/sam",
                                        username: "Sam", userID: "b")
        second.jellyfinServerID = "home"
        let other = MediaServerProfile(name: "Films", serverURL: "https://films.invalid", username: "Alex", userID: "a")
        defaults.set(try JSONEncoder().encode([first, second, other]), forKey: "NullSports.mediaServers")
        let film = MediaItem(id: "same-id", name: "Film", type: "Movie", overview: nil, productionYear: 2024,
                             primaryImageAspectRatio: nil, childCount: nil)
        let records = [first, second].enumerated().map { index, profile in
            LocalMediaPlayback(profileID: profile.id, item: film.servedBy(profile.id),
                               position: index == 0 ? 120 : 480, duration: 3600, updatedAt: Date(), completed: false)
        }
        defaults.set(try JSONEncoder().encode(records), forKey: "Lineup.localMediaPlayback.v1")
        let media = MediaLibrary(defaults: defaults)
        XCTAssertEqual(media.profiles.map(\.id), [first.id, other.id])
        XCTAssertEqual(media.continueWatching.map(\.position), [120])
        media.selectJellyfinAccount(second)
        XCTAssertEqual(media.profiles.map(\.id), [second.id, other.id])
        media.trackPlayback(of: film.servedBy(first.id), position: 900, duration: 3600)
        media.flushLocalPlayback()
        XCTAssertEqual(media.continueWatching.map(\.position), [480])
        let reopened = MediaLibrary(defaults: defaults)
        XCTAssertEqual(reopened.continueWatching.map(\.position), [480])
        reopened.selectJellyfinAccount(first)
        XCTAssertEqual(reopened.continueWatching.map(\.position), [120])
        XCTAssertEqual(reopened.savedProfiles.count, 3)
    }

    @MainActor
    func testPlayingFromAnotherSourceReportsOnlyToTheSelectedHouseholdUser() async throws {
        let suite = "JellyfinHouseholdReport.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alex = MediaServerProfile(name: "Home", serverURL: "https://home-contract.test", username: "Alex", userID: "alex")
        let sam = MediaServerProfile(name: "Home", serverURL: alex.serverURL, username: "Sam", userID: "sam")
        let films = MediaServerProfile(name: "Films", serverURL: "https://films-contract.test", username: "Shared", userID: "shared")
        defaults.set(try JSONEncoder().encode([alex, sam, films]), forKey: "NullSports.mediaServers")
        let network = session()
        defer { network.invalidateAndCancel() }
        let started = expectation(description: "The profile receives playback start")
        let stopped = expectation(description: "The profile receives playback stop")
        MediaIntegrationProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "alex")
            switch request.url?.path.lowercased() {
            case "/sessions/playing": started.fulfill()
            case "/sessions/playing/stopped": stopped.fulfill()
            default: XCTFail("Unexpected request")
            }
            return .json("", status: 204)
        }
        let media = MediaLibrary(defaults: defaults, trackingKey: { nil }, serverClientFactory: { profile in
            try JellyfinClient(serverURL: profile.serverURL, accessToken: profile.userID, deviceID: "fixture", session: network)
        })
        let movie = MediaItem(id: "home-film", name: "Film", type: "Movie", overview: nil, productionYear: 2024,
                              primaryImageAspectRatio: nil, childCount: nil).servedBy(alex.id)
        let id = UUID()
        media.beginPlaybackSession(for: movie, id: id, playedOn: films.id, serverItemID: "films-copy")
        media.reportTrackingSample(.init(playing: true, pictureInPicture: false, position: 120, duration: 3600),
                                   for: movie, sessionID: id)
        await fulfillment(of: [started], timeout: 3)
        media.endPlaybackSession(id)
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testSeerrPermissionFlagsKeepMovieSeriesAnd4KSeparate() throws {
        func user(_ permissions: Int) throws -> SeerrUser {
            try JSONDecoder().decode(SeerrUser.self, from: Data("{\"id\":7,\"permissions\":\(permissions)}".utf8))
        }
        XCTAssertTrue(try user(262144).canRequest(.movie))
        XCTAssertFalse(try user(262144).canRequest(.tv))
        XCTAssertFalse(try user(262144).canRequest(.movie, is4k: true))
        XCTAssertFalse(try user(2048).canRequest(.movie))
        XCTAssertTrue(try user(2048).canRequest(.movie, is4k: true))
        XCTAssertTrue(try user(262144 | 2048).canRequest(.movie, is4k: true))
        XCTAssertFalse(try user(32 | 4096).canRequest(.movie, is4k: true))
        XCTAssertTrue(try user(32 | 4096).canRequest(.tv, is4k: true))
        XCTAssertTrue(try user(2).managesRequests)
        XCTAssertFalse(try user(32).managesRequests)
    }

    func testSeerrStandardMovieUsesServerDefaultsWithExisting4KCopy() async throws {
        let network = session()
        defer { network.invalidateAndCancel() }
        let api = try SeerrClient(address: "https://seerr-contract.test", credential: .init(apiKey: "fixture"), session: network)
        MediaIntegrationProtocol.install { request in
            switch request.url?.path {
            case "/api/v1/auth/me": return .json(#"{"id":7,"permissions":32}"#)
            case "/api/v1/user/7/quota": return .json(#"{"movie":{"restricted":false}}"#)
            case "/api/v1/movie/42":
                return .json(#"{"id":42,"title":"Example","mediaInfo":{"status":1,"status4k":5,"requests":[{"id":8,"status":2,"is4k":true}]}}"#)
            case "/api/v1/request":
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(Set(body.keys), ["mediaId", "mediaType", "is4k"])
                XCTAssertEqual(body["mediaType"] as? String, "movie")
                XCTAssertEqual(body["is4k"] as? Bool, false)
                return .json(#"{"id":9,"status":2}"#, status: 201)
            default: throw URLError(.badURL)
            }
        }
        let result = try await api.request(id: 42, kind: .movie, seasons: [], is4k: false)
        XCTAssertEqual(result.id, 9)
        XCTAssertEqual(MediaIntegrationProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testSeerrServerDefaultsAllowMissingStandardSeasonInAvailableSeries() async throws {
        let network = session()
        defer { network.invalidateAndCancel() }
        let api = try SeerrClient(address: "https://seerr-contract.test", credential: .init(apiKey: "fixture"), session: network)
        let series = #"""
        {"id":42,"name":"Example","seasons":[{"id":1,"seasonNumber":1},{"id":2,"seasonNumber":2},{"id":3,"seasonNumber":3}],
         "mediaInfo":{"status":5,"seasons":[{"seasonNumber":1,"status":5},{"seasonNumber":2,"status4k":5}],
         "requests":[{"id":8,"status":1,"is4k":false,"seasons":[{"seasonNumber":3}]}]}}
        """#
        let title = try JSONDecoder().decode(SeerrTitle.self, from: Data(series.utf8))
        XCTAssertNil(title.requestBlockReason(kind: .tv, is4k: false))
        XCTAssertNil(title.requestBlockReason(kind: .tv, is4k: false, season: 2))
        XCTAssertNotNil(title.requestBlockReason(kind: .tv, is4k: false, season: 1))
        XCTAssertNotNil(title.requestBlockReason(kind: .tv, is4k: false, season: 3))
        XCTAssertNotNil(title.requestBlockReason(kind: .tv, is4k: true, season: 2))
        MediaIntegrationProtocol.install { request in
            switch request.url?.path {
            case "/api/v1/auth/me": return .json(#"{"id":7,"permissions":524288}"#)
            case "/api/v1/user/7/quota": return .json(#"{"tv":{"restricted":false}}"#)
            case "/api/v1/tv/42": return .json(series)
            case "/api/v1/request":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(Set(body.keys), ["mediaId", "mediaType", "is4k", "seasons"])
                XCTAssertEqual(body["is4k"] as? Bool, false)
                XCTAssertEqual(body["seasons"] as? [Int], [2])
                return .json(#"{"id":9,"status":1}"#, status: 201)
            default: throw URLError(.badURL)
            }
        }
        let result = try await api.request(id: 42, kind: .tv, seasons: [1, 2, 3], is4k: false)
        XCTAssertEqual(result.id, 9)
        XCTAssertEqual(MediaIntegrationProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
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

    func testSiloSetupAcceptsServerAndAPIAddressesWithTheirProxyPrefix() async throws {
        let network = session()
        defer { network.invalidateAndCancel() }
        MediaIntegrationProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://silo-contract.test/mount/api/v2/auth/login")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Silo-Device-Id"), "fixture-device")
            return .json(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"user":{"id":"42","username":"viewer"}}"#)
        }
        for address in ["silo-contract.test/mount", "https://silo-contract.test/mount/",
                        "https://silo-contract.test/mount/api/v2", "https://silo-contract.test/mount/api/v2/docs/",
                        "https://silo-contract.test/mount/api/v2/openapi.json"] {
            let client = try SiloClient(address: address, credential: .init(accessToken: ""), profileID: nil,
                                        deviceID: "fixture-device", session: network)
            let account = try await client.signIn(username: "viewer", password: "fixture")
            XCTAssertEqual(account.id, "42")
        }
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

    /// Silo says why it won't play a file; the viewer is told that, not a
    /// line about a compatible plan.
    func testSiloSaysWhyItWontPlayAFile() throws {
        let decision = try JSONDecoder().decode(SiloPlaybackDecision.self, from: Data(#"""
        {"protocol_version":3,"server_features":[],"outcome":"adaptation_unavailable",
         "terminal":{"reason":"transcode_limit_reached","message":"limit","retryable":true}}
        """#.utf8))
        let terminal = try XCTUnwrap(decision.terminal)
        XCTAssertNil(decision.playback_plan)
        XCTAssertTrue(SiloPlaybackSession.explanation(terminal).contains("converting as many videos"))
        let unknown = SiloPlaybackDecision.Terminal(reason: "something_new", message: "Server is busy.", retryable: false)
        XCTAssertEqual(SiloPlaybackSession.explanation(unknown), "Server is busy.")
        let policy = SiloPlaybackDecision.Terminal(reason: "routing_policy_unsatisfied", message: nil, retryable: false)
        XCTAssertTrue(SiloPlaybackSession.explanation(policy).contains("transcoding"))
    }

    /// A Silo library as Silo's own app shows it: its rows with their badges,
    /// a row of collections, the grid in the chosen order, and collections
    /// named for where they come from.
    func testSiloLibraryIsShownTheWayItsOwnAppShowsIt() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SiloClient(address: "https://silo-contract.test/base", credential: .init(accessToken: "fixture-key"),
                                    profileID: "profile:1", deviceID: "test", session: session)
        MediaIntegrationProtocol.install { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            switch url.path {
            case "/base/api/v2/library/1/sections":
                return .json(#"{"sections":[{"id":"top_rated","title":"Top Rated Movies","items":[{"content_id":"m1","type":"movie","title":"Beast","year":2017,"overlay_summary":{"resolution":"1080p","audio":"DTS","release_type":"Remux"}}],"total_count":40},{"id":"picks","title":"Collections","items":[],"collections":[{"id":"c9","source":"library","title":"Oscar Winners","poster_url":"","item_count":12,"library_id":"1"}]},{"id":"empty","title":"Nothing","items":[]}]}"#)
            case "/base/api/v2/catalog":
                XCTAssertEqual(value("library_id"), "1")
                XCTAssertEqual(value("sort"), "-added_at")
                XCTAssertEqual(value("type"), "movie")
                return .json(#"{"items":[{"content_id":"m2","type":"movie","title":"$"}],"page":{"has_more":true,"next_cursor":"c2"},"total":250}"#)
            case "/base/api/v2/library/1/collections":
                return .json(#"{"library_id":"1","collections":[{"id":"t1","title":"Trending Movies This Week","item_count":100,"poster_url":"","management_source":"tmdb","collection_type":"tmdb"}],"groups":[]}"#)
            default:
                XCTFail("Unexpected request \(url.path)")
                return .json("{}", status: 404)
            }
        }
        let library = MediaItem(id: "silo-library:1", name: "Movies", type: "CollectionFolder", overview: nil,
                                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        let home = try await client.serverLibraryHome(userID: "", library: library)
        XCTAssertEqual(home.rows.map(\.title), ["Top Rated Movies", "Collections"], "An empty row is left out")
        XCTAssertEqual(home.rows.first?.items.map(\.name), ["Beast"])
        XCTAssertEqual(home.badges["m1"], ServerLibraryBadges(top: ["1080P", "DTS"], bottom: "REMUX"))
        XCTAssertEqual(home.rows.first?.source, .section("top_rated"))
        let collection = try XCTUnwrap(home.rows.last?.collections.first)
        XCTAssertTrue(collection.item.id.hasPrefix("silo-curated:"))
        XCTAssertEqual(collection.item.childCount, 12)

        let page = try await client.serverLibraryTitles(
            userID: "", library: library,
            browse: ServerLibraryBrowse(sort: .added, descending: true, kind: .movies), cursor: nil)
        XCTAssertEqual(page.items.map(\.name), ["$"])
        XCTAssertEqual(page.next, "c2")
        XCTAssertEqual(page.total, 250)

        let collections = try await client.serverLibraryCollections(userID: "", library: library)
        XCTAssertEqual(collections.first?.detail, "Tmdb", "Named for where it comes from, as Silo's app names it")
    }

    /// Silo's Home, its letters, a jump, a title's extras and the Calendar,
    /// asked for as Silo's own app asks.
    func testSiloPagesAreReadTheWaySilosOwnAppReadsThem() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let client = try SiloClient(address: "https://silo-contract.test/base", credential: .init(accessToken: "fixture-key"),
                                    profileID: "profile:1", deviceID: "test", session: session)
        MediaIntegrationProtocol.install { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/base/api/v2/home/sections"):
                return .json(#"{"sections":[{"id":"cw","title":"Continue Watching","section_type":"continue_watching","items":[{"content_id":"e1","type":"episode","title":"Pilot","series_id":"s1","progress_updated_at":"2026-11-18T10:00:00.123Z"}]},{"id":"nu","title":"Next Up","section_type":"next_up","items":[{"content_id":"e2","type":"episode","title":"Two","series_id":"s2"}]},{"id":"new","title":"Recently Added","section_type":"recently_added","items":[{"content_id":"m1","type":"movie","title":"Beast"}]}]}"#)
            case ("PUT", "/base/api/v2/home/dismissals/continue_watching/e1"):
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(body["progress_updated_at"] as? String, "2026-11-18T10:00:00.123Z",
                               "Sent back exactly as Silo gave it")
                return .init(status: 204, json: "")
            case ("POST", "/base/api/v2/catalog/letters"):
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(body["library_id"] as? String, "1")
                XCTAssertEqual(body["order"] as? String, "asc")
                XCTAssertEqual(body["type"] as? String, "movie")
                return .json(#"{"letters":[{"letter":"A","position":0,"count":30},{"letter":"M","position":420,"count":12}],"runs":[],"total":432}"#)
            case ("GET", "/base/api/v2/catalog"):
                XCTAssertEqual(value("seek"), "420")
                XCTAssertEqual(value("sort"), "title")
                return .json(#"{"items":[{"content_id":"m9","type":"movie","title":"Memento"}],"page":{"has_more":true,"next_cursor":"after-m9"}}"#)
            case ("GET", "/base/api/v2/catalog/items/m1"):
                return .json(#"{"content_id":"m1","type":"movie","title":"Beast","user_state":{"in_watchlist":true},"videos":[{"name":"Official Trailer","site":"YouTube","site_key":"dQw4w9WgXcQ","type":"Trailer"},{"name":"Elsewhere","site":"Vimeo","site_key":"123","type":"Clip"}],"cast":[{"name":"Jessie Buckley","person_id":"p7","character":"Moll"}],"crew":[]}"#)
            case ("GET", "/base/api/v2/catalog/items/m1/box-set"):
                return .json(#"{"box_set":{"id":"10","title":"Beast Box Set","first_year":2017,"last_year":2021,"items":[{"content_id":"m1","type":"movie","title":"Beast"},{"content_id":"m3","type":"movie","title":"Beast 2"}]}}"#)
            case ("GET", "/base/api/v2/calendar"):
                XCTAssertEqual(value("start"), "2026-11-16")
                XCTAssertEqual(value("end"), "2026-11-22")
                XCTAssertEqual(value("timezone"), "UTC")
                return .json(#"{"events":[{"date":"2026-11-17","items":[{"content_id":"e5","title":"Severance","type":"episode","season_number":2,"episode_number":5,"episode_title":"Trojan's Horse","series_id":"s5","air_at":"2026-11-17T02:00:00Z","badges":["season_premiere"],"watched":false}]}]}"#)
            default:
                XCTFail("Unexpected request \(request.httpMethod ?? "") \(url.path)")
                return .json("{}", status: 404)
            }
        }

        let home = try await client.siloHome()
        XCTAssertEqual(home.rows.map(\.title), ["Continue Watching", "Next Up", "Recently Added"])
        XCTAssertEqual(home.dismissals["cw"]?["e1"]?.surface, .continueWatching)
        XCTAssertEqual(home.dismissals["nu"]?["e2"], SiloDismissal(surface: .nextUp, progressUpdatedAt: nil, seriesID: "s2"))
        XCTAssertNil(home.dismissals["new"], "Only Continue Watching and Next Up cards can be taken off")
        try await client.siloDismiss(itemID: "e1", try XCTUnwrap(home.dismissals["cw"]?["e1"]))

        let library = MediaItem(id: "silo-library:1", name: "Movies", type: "CollectionFolder", overview: nil,
                                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        let browse = ServerLibraryBrowse(sort: .title, descending: false, kind: .movies)
        let letters = try await client.serverLibraryLetters(library: library, browse: browse)
        XCTAssertEqual(letters.letters.map(\.letter), ["A", "M"])
        XCTAssertEqual(letters.total, 432)
        let jumped = try await client.serverLibraryTitles(library: library, browse: browse, from: 420)
        XCTAssertEqual(jumped.items.map(\.name), ["Memento"])
        XCTAssertEqual(jumped.next, "after-m9")
        var filtered = browse
        filtered.genre = "Drama"
        XCTAssertFalse(filtered.jumpsByLetter, "A genre's titles are not what Silo counts letters for")

        let extras = try await client.siloTitleExtras(itemID: "m1", isMovie: true)
        XCTAssertTrue(extras.inWatchlist)
        XCTAssertEqual(extras.trailers.map(\.url), ["https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
                       "Only YouTube trailers, which open and show a thumbnail")
        XCTAssertEqual(extras.people["Jessie Buckley"], "p7")
        XCTAssertEqual(extras.boxSet?.title, "Beast Box Set")
        XCTAssertEqual(extras.boxSet?.years, "2017–2021")
        XCTAssertEqual(extras.boxSet?.items.map(\.name), ["Beast", "Beast 2"])

        var "America/Los_Angeles" = Calendar(identifier: .gregorian)
        "America/Los_Angeles".timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let monday = try XCTUnwrap("America/Los_Angeles".date(from: DateComponents(year: 2026, month: 11, day: 16)))
        let days = try await client.siloCalendar(from: monday, days: 7, timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
        let event = try XCTUnwrap(days.first?.events.first)
        XCTAssertEqual(event.episodeCode, "S2 · E5")
        XCTAssertEqual(event.badges, ["Season Premiere"])
        XCTAssertNotNil(event.airsAt)
    }

    func testServerLibraryPagingStopsAtTheEnd() {
        XCTAssertEqual(ServerLibraryQuery.next(after: 0, read: 60, total: 130), "60")
        XCTAssertNil(ServerLibraryQuery.next(after: 120, read: 10, total: 130))
        XCTAssertNil(ServerLibraryQuery.next(after: 0, read: 12, total: nil), "A short page is the last")
        XCTAssertEqual(ServerLibraryQuery.next(after: 0, read: 60, total: nil), "60")
        XCTAssertEqual(ServerLibraryBadges(top: [" 4k ", ""], bottom: " webrip").top, ["4K"])
        XCTAssertTrue(ServerLibraryBadges(top: [], bottom: "  ").isEmpty)
    }

    /// The stream's address as Silo's own player builds it: under /api/v2,
    /// with the account's token, and a proxy node's address left alone.
    func testSiloStreamAddressIsBuiltAsSilosOwnPlayerBuildsIt() throws {
        let base = try XCTUnwrap(URL(string: "https://silo.example.test/base"))
        func address(_ path: String, token: String? = "a+b") -> String? {
            SiloPlaybackSession.mediaURL(path, base: base, token: token)?.absoluteString
        }
        XCTAssertEqual(address("/stream/s1?st=x%2By"),
                       "https://silo.example.test/base/api/v2/stream/s1?st=x%2By&token=a%2Bb")
        XCTAssertEqual(address("/api/v1/stream/s1"), "https://silo.example.test/base/api/v2/stream/s1?token=a%2Bb")
        XCTAssertEqual(address("/api/v2/playback/transcode/s1/master.m3u8?st=x", token: nil),
                       "https://silo.example.test/base/api/v2/playback/transcode/s1/master.m3u8?st=x")
        XCTAssertEqual(address("/base/api/v2/stream/s1?st=x"),
                       "https://silo.example.test/base/api/v2/stream/s1?st=x&token=a%2Bb")
        XCTAssertEqual(address("http://node.example.test:8097/stream/remux/opaque"),
                       "http://node.example.test:8097/stream/remux/opaque", "A proxy is never sent the account's token")
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
                // The engines show HDR and Dolby Vision from the file as it
                // is, so Silo sends a 4K HDR film untouched.
                let context = try XCTUnwrap(body["client_playback_context"] as? [String: Any])
                let deliveries = try XCTUnwrap(context["deliveries"] as? [String: [String: Any]])
                XCTAssertEqual(deliveries["original_http"]?["validated_claims"] as? [String],
                               ["client_managed_dynamic_range_v1"])
                XCTAssertEqual(deliveries["hls"]?["validated_claims"] as? [String], [])
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
            let stopID = try XCTUnwrap(body["stop_id"] as? String)
            let uuid = try XCTUnwrap(UUID(uuidString: stopID))
            XCTAssertEqual(stopID, uuid.uuidString.lowercased())
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

    func testSeerrMediaServerSignInsUseTheConfiguredSeerrSession() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        for method in [SeerrSignInMethod.jellyfin, .emby] {
            let client = try SeerrClient(address: "https://seerr-contract.test/base", credential: .init(), session: session)
            MediaIntegrationProtocol.install { request in
                let body = try MediaIntegrationProtocol.body(request)
                XCTAssertEqual(request.url!.path, "/base/api/v1/auth/jellyfin")
                XCTAssertEqual(body["serverType"] as? Int, method == .emby ? 3 : 2)
                XCTAssertEqual(body["username"] as? String, "viewer")
                XCTAssertNil(body["hostname"], "The client must not reconfigure Seerr's linked media server")
                return .init(status: 200, json: #"{"id":7,"permissions":32}"#,
                    headers: ["Set-Cookie": "connect.sid=fixture-session; Path=/base; HttpOnly"])
            }
            let signedIn = try await client.signInMediaServer(username: "viewer", password: "fixture", emby: method == .emby)
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

private final class MediaIntegrationProtocol: URLProtocol {
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
