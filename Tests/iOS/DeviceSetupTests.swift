import Network
import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

/// Setting up an Apple TV from the phone: the code, the sealing, what is sent,
/// how the TV takes it, and the trip across the network between the two.
@MainActor
final class DeviceSetupTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let name = "DeviceSetupTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (defaults, name)
    }

    private func list(_ entries: [(UUID, String)]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries.map { ["id": $0.0.uuidString, "name": $0.1] })
    }

    // MARK: The code

    func testACodeComesBackWholeFromTheLinkTheTVShows() {
        let pairing = DeviceSetupPairing.make()
        XCTAssertEqual(DeviceSetupPairing(url: pairing.url), pairing)
        XCTAssertEqual(pairing.url.scheme, "lineup")
        XCTAssertEqual(pairing.secret.count, 32)
        XCTAssertNotEqual(DeviceSetupPairing.make().secret, pairing.secret, "each screen shows a code of its own")
    }

    func testLinksThatAreNotASetupCodeAreRefused() {
        let good = DeviceSetupPairing.make().url.absoluteString
        let bad = [
            "https://example.com/setup?v=1",
            "lineup://other?v=1",
            good.replacingOccurrences(of: "v=1", with: "v=2"),
            "lineup://setup?v=1&s=TV&k=c2hvcnQ"
        ]
        for text in bad {
            XCTAssertNil(URL(string: text).flatMap(DeviceSetupPairing.init(url:)), text)
        }
    }

    // MARK: Sealing

    func testOnlyTheCodeThatSealedASetupCanOpenIt() throws {
        let pairing = DeviceSetupPairing.make()
        let words = Data("the provider's password".utf8)
        let sealed = try pairing.seal(words, .toTV)
        XCTAssertNil(sealed.range(of: words), "nothing on the network reads it")
        XCTAssertEqual(try pairing.open(sealed, .toTV), words)
        XCTAssertThrowsError(try DeviceSetupPairing.make().open(sealed, .toTV))
        XCTAssertThrowsError(try DeviceSetupPairing(service: "Lineup Apple TV 0000", secret: pairing.secret)
            .open(sealed, .toTV), "the same secret on another TV's name is another key")
        XCTAssertThrowsError(try pairing.open(sealed, .reply), "a message to the TV can't pass as its answer")
        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try pairing.open(tampered, .toTV))
    }

    // MARK: What is sent

    func testTheSetupCarriesSourcesSignInsAndSettingsButNotThisDevicesOwn() throws {
        let (phone, _) = try defaults()
        let iptv = UUID(), server = UUID()
        phone.set(try list([(iptv, "Provider")]), forKey: DeviceSetup.providersKey)
        phone.set(try list([(server, "Jellyfin")]), forKey: DeviceSetup.serversKey)
        phone.set([1, 2, 3], forKey: "NullSports.favoriteStreams.\(iptv.uuidString)")
        phone.set(Data("{}".utf8), forKey: SeerrStore.key)
        phone.set("this phone", forKey: "NullSports.mediaDeviceID")
        phone.set(Data("history".utf8), forKey: "Lineup.localMediaPlayback.v1")
        let vault = Vault(passwords: [iptv: "secret"], tokens: [server: "token", SeerrStore.credentialID: "seerr"])

        let payload = DeviceSetup.capture(defaults: phone, secrets: vault.secrets, library: .init())

        for key in [DeviceSetup.providersKey, DeviceSetup.serversKey, SeerrStore.key,
                    "NullSports.favoriteStreams.\(iptv.uuidString)"] {
            XCTAssertNotNil(payload.values[key], key)
        }
        XCTAssertNil(payload.values["NullSports.mediaDeviceID"], "each device keeps its own id")
        XCTAssertNil(payload.values["Lineup.localMediaPlayback.v1"],
                     "history is merged into the TV's, never written over it")
        XCTAssertEqual(payload.providerPasswords, [iptv.uuidString: "secret"])
        XCTAssertEqual(payload.mediaTokens, [server.uuidString: "token", SeerrStore.credentialID.uuidString: "seerr"])
        XCTAssertEqual(payload.count(of: DeviceSetup.providersKey), 1)
    }

    // MARK: How the TV takes it

    func testTheTVKeepsItsOwnSourcesAndTakesThePhonesUnderTheSameIDs() throws {
        let (phone, _) = try defaults()
        let (tv, _) = try defaults()
        let shared = UUID(), phoneOnly = UUID(), tvOnly = UUID()
        phone.set(try list([(shared, "Phone name"), (phoneOnly, "Phone only")]), forKey: DeviceSetup.providersKey)
        phone.set("00FF00", forKey: "lineup.appearance.accent")
        tv.set(try list([(tvOnly, "TV only"), (shared, "Old name")]), forKey: DeviceSetup.providersKey)
        let phoneVault = Vault(passwords: [shared: "p1", phoneOnly: "p2"])
        let tvVault = Vault(passwords: [tvOnly: "tv"])
        var payload = DeviceSetup.capture(defaults: phone, secrets: phoneVault.secrets, library: .init())
        payload.values["NullSports.mediaDeviceID"] = try PropertyListSerialization.data(
            fromPropertyList: "intruder", format: .binary, options: 0)

        let applied = try DeviceSetup.apply(payload, defaults: tv, secrets: tvVault.secrets)

        XCTAssertEqual(applied, DeviceSetup.Applied(providers: 2, servers: 0))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(tv.data(forKey: DeviceSetup.providersKey))) as? [[String: Any]])
        XCTAssertEqual(saved.compactMap { $0["id"] as? String }, [shared, phoneOnly, tvOnly].map(\.uuidString))
        XCTAssertEqual(saved.first?["name"] as? String, "Phone name")
        XCTAssertEqual(tvVault.passwords, [shared: "p1", phoneOnly: "p2", tvOnly: "tv"])
        XCTAssertEqual(tv.string(forKey: "lineup.appearance.accent"), "00FF00")
        XCTAssertNotEqual(tv.string(forKey: "NullSports.mediaDeviceID"), "intruder",
                          "a setting the phone doesn't send is never written")
    }

    func testTheSameServerAndProviderAddedOnEachDeviceBecomeOne() throws {
        let (phone, _) = try defaults()
        let (tv, tvName) = try defaults()
        let phoneServer = UUID(), tvServer = UUID(), phoneProvider = UUID(), tvProvider = UUID()
        phone.set(try JSONSerialization.data(withJSONObject: [[
            "id": phoneServer.uuidString, "name": "Jellyfin", "serverURL": "http://jellyfin.local:8096/",
            "username": "viewer", "userID": "ABC123", "software": "jellyfin"]]), forKey: DeviceSetup.serversKey)
        tv.set(try JSONSerialization.data(withJSONObject: [[
            "id": tvServer.uuidString, "name": "Home", "serverURL": "http://192.168.1.20:8096",
            "username": "viewer", "userID": "abc123", "software": "jellyfin"]]), forKey: DeviceSetup.serversKey)
        phone.set(try JSONSerialization.data(withJSONObject: [[
            "id": phoneProvider.uuidString, "name": "IPTV", "serverURL": "http://iptv.example:8080",
            "username": "me"]]), forKey: DeviceSetup.providersKey)
        tv.set(try JSONSerialization.data(withJSONObject: [[
            "id": tvProvider.uuidString, "name": "IPTV", "serverURL": "HTTP://iptv.example:8080/",
            "username": "Me"]]), forKey: DeviceSetup.providersKey)
        phone.set([6, 7], forKey: "NullSports.favoriteStreams.\(phoneProvider.uuidString)")
        tv.set([5, 6], forKey: "NullSports.favoriteStreams.\(tvProvider.uuidString)")
        tv.set(["team"], forKey: "NullSports.followedTeams.\(tvProvider.uuidString)")
        let payload = DeviceSetup.capture(defaults: phone,
                                          secrets: Vault(passwords: [phoneProvider: "p"], tokens: [phoneServer: "t"]).secrets,
                                          library: .init())
        let tvVault = Vault()

        let applied = try DeviceSetup.apply(payload, defaults: tv, secrets: tvVault.secrets)

        XCTAssertEqual(applied.renamed, [tvServer.uuidString: phoneServer.uuidString,
                                         tvProvider.uuidString: phoneProvider.uuidString])
        XCTAssertEqual(DeviceSetup.profileIDs(in: tv.data(forKey: DeviceSetup.serversKey)), [phoneServer],
                       "one server, not one per device")
        XCTAssertEqual(DeviceSetup.profileIDs(in: tv.data(forKey: DeviceSetup.providersKey)), [phoneProvider])
        XCTAssertEqual(tv.array(forKey: "NullSports.favoriteStreams.\(phoneProvider.uuidString)") as? [Int], [6, 7, 5],
                       "the phone's favorites, then the ones only the TV had")
        XCTAssertEqual(tv.array(forKey: "NullSports.followedTeams.\(phoneProvider.uuidString)") as? [String], ["team"],
                       "what the TV kept for its copy goes with the phone's")
        let saved = UserDefaults.standard.persistentDomain(forName: tvName) ?? [:]
        XCTAssertNil(saved["NullSports.favoriteStreams.\(tvProvider.uuidString)"])
        XCTAssertNil(saved["NullSports.followedTeams.\(tvProvider.uuidString)"])
        XCTAssertEqual(tvVault.passwords, [phoneProvider: "p"])
    }

    func testTwoCopiesOfAServersHistoryBecomeOneRecordEachTheFurtherPlaceKept() throws {
        let (tvDefaults, _) = try defaults()
        let old = UUID(), new = UUID()
        let servers = [MediaServerProfile(id: new, name: "Jellyfin", serverURL: "http://server", username: "viewer", userID: "u")]
        tvDefaults.set(try JSONEncoder().encode(servers), forKey: DeviceSetup.serversKey)
        func show(on server: UUID, at position: TimeInterval, day: TimeInterval) -> LocalMediaPlayback {
            let item = MediaItem(id: "terminal-list", name: "The Terminal List", type: "Movie", overview: nil,
                                 productionYear: 2022, primaryImageAspectRatio: nil, childCount: nil, serverID: server)
            return LocalMediaPlayback(profileID: server, item: item, position: position, duration: 3_600,
                                      updatedAt: Date(timeIntervalSince1970: day), completed: false)
        }
        tvDefaults.set(try JSONEncoder().encode([show(on: old, at: 600, day: 1_000), show(on: new, at: 1_800, day: 2_000)]),
                       forKey: "Lineup.localMediaPlayback.v1")
        let tv = MediaLibrary(defaults: tvDefaults)

        tv.adoptProfileIDs([old.uuidString: new.uuidString])

        XCTAssertEqual(tv.localPlayback.count, 1, "the title shows once")
        XCTAssertEqual(tv.localPlayback.first?.profileID, new)
        XCTAssertEqual(tv.localPlayback.first?.item.serverID, new)
        XCTAssertEqual(tv.localPlayback.first?.position, 1_800, "the further place stays")
    }

    func testASetupFromAnotherVersionChangesNothing() throws {
        let (phone, _) = try defaults()
        let (tv, tvName) = try defaults()
        let id = UUID()
        phone.set(try list([(id, "Provider")]), forKey: DeviceSetup.providersKey)
        let vault = Vault(passwords: [id: "secret"])
        var payload = DeviceSetup.capture(defaults: phone, secrets: vault.secrets, library: .init())
        payload.version = DeviceSetupPayload.currentVersion + 1
        let tvVault = Vault()

        XCTAssertThrowsError(try DeviceSetup.apply(payload, defaults: tv, secrets: tvVault.secrets)) {
            XCTAssertEqual($0 as? DeviceSetupError, .otherVersion)
        }
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: tvName)?[DeviceSetup.providersKey])
        XCTAssertTrue(tvVault.passwords.isEmpty)
    }

    func testAKeychainThatRefusesASignInLeavesTheTVAsItWas() throws {
        let (phone, _) = try defaults()
        let (tv, tvName) = try defaults()
        let id = UUID()
        phone.set(try list([(id, "Provider")]), forKey: DeviceSetup.providersKey)
        let payload = DeviceSetup.capture(defaults: phone, secrets: Vault(passwords: [id: "secret"]).secrets,
                                          library: .init())
        let refusing = Vault()
        refusing.refusesToSave = true

        XCTAssertThrowsError(try DeviceSetup.apply(payload, defaults: tv, secrets: refusing.secrets)) {
            XCTAssertEqual($0 as? DeviceSetupError, .keychain)
        }
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: tvName)?[DeviceSetup.providersKey],
                     "no source arrives without the sign-in that opens it")
    }

    func testThePhonesWatchHistoryJoinsTheTVsAndTheFurtherPlaceWins() throws {
        let (tvDefaults, _) = try defaults()
        let server = MediaServerProfile(name: "Server", serverURL: "http://server", username: "viewer", userID: "user")
        tvDefaults.set(try JSONEncoder().encode([server]), forKey: DeviceSetup.serversKey)
        func movie(_ id: String) -> MediaItem {
            MediaItem(id: id, name: id, type: "Movie", overview: nil, productionYear: 2026,
                      primaryImageAspectRatio: nil, childCount: nil, serverID: server.id)
        }
        func played(_ id: String, at position: TimeInterval, on day: TimeInterval, done: Bool = false) -> LocalMediaPlayback {
            LocalMediaPlayback(profileID: server.id, item: movie(id), position: position, duration: 6_000,
                               updatedAt: Date(timeIntervalSince1970: day), completed: done)
        }
        tvDefaults.set(try JSONEncoder().encode([played("both", at: 600, on: 1_000), played("tv", at: 100, on: 1_000)]),
                       forKey: "Lineup.localMediaPlayback.v1")
        let tv = MediaLibrary(defaults: tvDefaults)

        tv.adoptPlaybackHistory([played("both", at: 3_000, on: 2_000), played("phone", at: 6_000, on: 2_000, done: true)],
                                favorites: [LocalMediaFavorite(profileID: server.id, item: movie("phone"),
                                                               addedAt: Date(timeIntervalSince1970: 2_000))],
                                dismissals: [])

        let byID = Dictionary(uniqueKeysWithValues: tv.localPlayback.map { ($0.item.id, $0) })
        XCTAssertEqual(Set(byID.keys), ["both", "tv", "phone"], "nothing the TV watched is lost")
        XCTAssertEqual(byID["both"]?.position, 3_000, "the further place wins")
        XCTAssertEqual(byID["tv"]?.position, 100)
        XCTAssertEqual(byID["phone"]?.completed, true)
        XCTAssertEqual(tv.localFavorites.map(\.item.id), ["phone"])
        XCTAssertEqual(Set(MediaLibrary(defaults: tvDefaults).localPlayback.map(\.item.id)), ["both", "tv", "phone"],
                       "saved, so it is there after a relaunch")

        tv.adoptPlaybackHistory([played("both", at: 10, on: 5_000)], favorites: [], dismissals: [])
        XCTAssertEqual(tv.localPlayback.first { $0.item.id == "both" }?.position, 3_000,
                       "a place further back never undoes this one, however recently it was played")
    }

    private func episode(_ number: Int, on server: UUID) -> MediaItem {
        MediaItem(id: "e\(number)", name: "Episode \(number)", type: "Episode", overview: nil,
                  productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                  indexNumber: number, parentIndexNumber: 1, seriesName: "Show", seriesID: "show",
                  serverID: server)
    }

    private func watched(_ number: Int, on server: UUID, at day: TimeInterval,
                         stoppedAt position: TimeInterval? = nil) -> LocalMediaPlayback {
        LocalMediaPlayback(profileID: server, item: episode(number, on: server), position: position ?? 3_000,
                           duration: 3_000, updatedAt: Date(timeIntervalSince1970: day), completed: position == nil)
    }

    /// Where the show's Play button picks up, from these records alone.
    private func resume(_ records: [LocalMediaPlayback], on server: UUID) -> String? {
        let finished = Set(records.filter(\.completed).map(\.item.id))
        return SeriesResumePolicy.target(episodes: (1...8).map { episode($0, on: server) }, records: records,
                                         serverNext: nil, isWatched: { finished.contains($0.id) })?.id
    }

    func testTheDeviceFurtherIntoAShowKeepsItsPlaceThoughTheOtherPlayedItSince() throws {
        let server = UUID()
        // The TV is partway through episode 5. The phone, played since, is
        // partway through episode 3.
        let tv = (1...4).map { watched($0, on: server, at: 1_000 + Double($0)) }
            + [watched(5, on: server, at: 1_010, stoppedAt: 900)]
        let phone = [watched(1, on: server, at: 2_000), watched(2, on: server, at: 2_001),
                     watched(3, on: server, at: 2_002, stoppedAt: 600)]
        XCTAssertEqual(resume(phone, on: server), "e3")

        let merged = MediaLibrary.mergedHistory(tv, adding: phone)

        XCTAssertEqual(resume(merged, on: server), "e5", "the show picks up where the TV is")
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.item.id, $0) })
        XCTAssertEqual(Set(byID.keys), ["e1", "e2", "e3", "e4", "e5"])
        XCTAssertEqual(byID["e3"]?.completed, true, "the phone's place in episode 3 stays behind")
        XCTAssertEqual(byID["e5"]?.position, 900)
        XCTAssertLessThan(try XCTUnwrap(byID["e2"]).updatedAt, Date(timeIntervalSince1970: 1_010),
                          "the phone's finished episodes count, but never as the show's latest")
    }

    func testThePhoneFurtherIntoAShowMovesTheTVOnThoughTheTVPlayedItSince() {
        let server = UUID()
        let tv = [watched(1, on: server, at: 3_000), watched(2, on: server, at: 3_001, stoppedAt: 400)]
        let phone = (1...5).map { watched($0, on: server, at: 1_000 + Double($0)) }
            + [watched(6, on: server, at: 1_010, stoppedAt: 1_200)]

        let merged = MediaLibrary.mergedHistory(tv, adding: phone)

        XCTAssertEqual(resume(merged, on: server), "e6", "the show picks up where the phone is")
        XCTAssertEqual(merged.filter { !$0.completed }.map(\.item.id), ["e6"],
                       "the TV's place in episode 2 stays behind")
        XCTAssertEqual(merged.count, 6)
    }

    func testAShowOnlyOneDeviceHasComesWhole() {
        let server = UUID()
        let phone = [watched(1, on: server, at: 1_000), watched(2, on: server, at: 1_001, stoppedAt: 300)]

        let merged = MediaLibrary.mergedHistory([], adding: phone)

        XCTAssertEqual(merged, phone)
        XCTAssertEqual(resume(merged, on: server), "e2")
    }

    // MARK: Across the network

    func testThePhonesSetupCrossesTheNetworkToTheTVShowingItsCode() async throws {
        var taken: DeviceSetupPayload?
        var settled = false
        let receiver = DeviceSetupReceiver(advertises: false, take: { payload in
            taken = payload
            return DeviceSetup.Applied(providers: 1, servers: 2)
        }, settle: { _, _ in settled = true })
        receiver.start()
        defer { receiver.stop() }
        let port = try await listening(receiver)
        var choices = DeviceSetupPayload.LibraryChoices()
        choices.localTracking = false
        let payload = DeviceSetupPayload(values: ["lineup.appearance.accent": Data([1])],
                                         providerPasswords: ["id": "secret"], mediaTokens: [:], library: choices)

        try await DeviceSetupSender.send(payload, pairing: receiver.pairing, to: endpoint(port))

        try await until { receiver.phase == .finished(DeviceSetup.Applied(providers: 1, servers: 2)) }
        XCTAssertEqual(taken?.providerPasswords, ["id": "secret"])
        XCTAssertEqual(taken?.library.localTracking, false)
        XCTAssertTrue(settled)
    }

    func testACodeFromAnotherScreenIsTurnedAwayAndTheTVKeepsWaiting() async throws {
        var takes = 0
        let receiver = DeviceSetupReceiver(advertises: false, take: { _ in
            takes += 1
            return DeviceSetup.Applied(providers: 0, servers: 0)
        }, settle: { _, _ in })
        receiver.start()
        defer { receiver.stop() }
        let port = try await listening(receiver)
        let payload = DeviceSetupPayload(values: [:], providerPasswords: [:], mediaTokens: [:], library: .init())

        do {
            try await DeviceSetupSender.send(payload, pairing: .make(), to: endpoint(port), answer: .seconds(10))
            XCTFail("a setup sealed with another code was taken")
        } catch {
            XCTAssertEqual(error as? DeviceSetupError, .wrongCode)
        }
        XCTAssertEqual(takes, 0)
        XCTAssertEqual(receiver.phase, .waiting)

        try await DeviceSetupSender.send(payload, pairing: receiver.pairing, to: endpoint(port))
        try await until {
            if case .finished = receiver.phase { return true }
            return false
        }
        XCTAssertEqual(takes, 1)
    }

    // MARK: Helpers

    private func listening(_ receiver: DeviceSetupReceiver) async throws -> NWEndpoint.Port {
        try await until { receiver.port != nil && receiver.phase == .waiting }
        return try XCTUnwrap(receiver.port.flatMap(NWEndpoint.Port.init(rawValue:)))
    }

    private func endpoint(_ port: NWEndpoint.Port) -> NWEndpoint {
        .hostPort(host: "localhost", port: port)
    }

    private func until(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("timed out")
                throw DeviceSetupError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Sign-ins kept in memory, as the Keychain keeps them.
private final class Vault: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPasswords: [UUID: String]
    private var storedTokens: [UUID: String]
    private var refusing = false

    init(passwords: [UUID: String] = [:], tokens: [UUID: String] = [:]) {
        storedPasswords = passwords
        storedTokens = tokens
    }

    var refusesToSave: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }

    var passwords: [UUID: String] { lock.withLock { storedPasswords } }

    var secrets: DeviceSetup.Secrets {
        DeviceSetup.Secrets(
            providerPassword: { id in self.lock.withLock { self.storedPasswords[id] } },
            saveProviderPassword: { password, id in
                try self.lock.withLock {
                    if self.refusing { throw DeviceSetupError.keychain }
                    self.storedPasswords[id] = password
                }
            },
            mediaToken: { id in self.lock.withLock { self.storedTokens[id] } },
            saveMediaToken: { token, id in
                try self.lock.withLock {
                    if self.refusing { throw DeviceSetupError.keychain }
                    self.storedTokens[id] = token
                }
            })
    }
}
