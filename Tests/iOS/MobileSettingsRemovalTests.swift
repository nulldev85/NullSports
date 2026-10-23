import SwiftUI
import XCTest
@testable import LineupiOS

@MainActor
final class MobileSettingsRemovalTests: XCTestCase {
    func testProviderConfirmationRemovesItsCapturedAccountAfterSheetDismissalAndPersists() async throws {
        let suite = "MobileSettingsRemovalTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Matching names must not let removal choose a different account.
        let first = XtreamProfile(name: "My IPTV", serverURL: "https://example.invalid", username: "one")
        var second = XtreamProfile(name: "My IPTV", serverURL: "https://example.invalid/list.m3u", username: "")
        second.connectionKind = "m3u"
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.profiles")
        defaults.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        defaults.set([7], forKey: "NullSports.favoriteStreams.\(first.id.uuidString)")
        let library = SportsLibrary(profileDefaults: defaults)

        for profile in [second, first] {
            var pending: XtreamProfile? = profile
            let presented = Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
            let choices = MobileSettingsRemovalChoices.provider(pending, library: library)
            let confirm = try XCTUnwrap(choices.first)
            XCTAssertEqual(choices.count, 1)
            XCTAssertTrue(confirm.isDestructive)
            // This is the production choice sheet's order: dismiss, then act.
            presented.wrappedValue = false
            XCTAssertNil(pending)
            confirm.action()
            try await waitForRemoval(profile, from: library)
            XCTAssertEqual(SportsLibrary(profileDefaults: defaults).profiles, library.profiles)
            if profile == second {
                XCTAssertEqual(library.profiles, [first])
                XCTAssertEqual(library.activeProfile, first)
                XCTAssertEqual(library.favoriteStreamOrder, [7])
            }
        }
        XCTAssertFalse(library.hasProfile)
        XCTAssertTrue(library.favoriteStreamOrder.isEmpty)
        XCTAssertNil(defaults.object(forKey: "NullSports.activeProfile"))
    }

    func testMediaConfirmationRemovesItsCapturedServerAfterSheetDismissalForEveryBrand() throws {
        for brand in MediaServerBrand.allCases {
            let suite = "MobileSettingsRemovalTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = MediaServerProfile(name: "My Server", serverURL: "https://example.invalid",
                username: "one", userID: "one", software: brand)
            let second = MediaServerProfile(name: "My Server", serverURL: "https://example.invalid",
                username: "two", userID: "two", software: brand)
            defaults.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.mediaServers")
            let media = MediaLibrary(defaults: defaults)

            for profile in [second, first] {
                var pending: MediaServerProfile? = profile
                let presented = Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
                let choices = MobileSettingsRemovalChoices.mediaServer(pending, media: media)
                let confirm = try XCTUnwrap(choices.first)
                XCTAssertEqual(choices.count, 1)
                XCTAssertTrue(confirm.isDestructive)
                presented.wrappedValue = false
                XCTAssertNil(pending)
                confirm.action()
                XCTAssertFalse(media.profiles.contains(profile))
                XCTAssertEqual(MediaLibrary(defaults: defaults).profiles, media.profiles)
                if profile == second { XCTAssertEqual(media.profiles, [first]) }
            }
            XCTAssertFalse(media.hasAnySource)
        }
    }

    func testDismissingWithoutConfirmingKeepsBothSourcesAndEmptySelectionsOfferNoRemoval() throws {
        let suite = "MobileSettingsRemovalTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = XtreamProfile(name: "Provider", serverURL: "https://example.invalid", username: "one")
        let server = MediaServerProfile(name: "Server", serverURL: "https://example.invalid", username: "one", userID: "one")
        defaults.set(try JSONEncoder().encode([provider]), forKey: "NullSports.profiles")
        defaults.set(provider.id.uuidString, forKey: "NullSports.activeProfile")
        defaults.set(try JSONEncoder().encode([server]), forKey: "NullSports.mediaServers")
        let library = SportsLibrary(profileDefaults: defaults)
        let media = MediaLibrary(defaults: defaults)
        var pendingProvider: XtreamProfile? = provider
        var pendingServer: MediaServerProfile? = server
        XCTAssertEqual(MobileSettingsRemovalChoices.provider(pendingProvider, library: library).count, 1)
        XCTAssertEqual(MobileSettingsRemovalChoices.mediaServer(pendingServer, media: media).count, 1)
        // Cancel/outside tap clears presentation without invoking a row.
        pendingProvider = nil
        pendingServer = nil
        XCTAssertTrue(MobileSettingsRemovalChoices.provider(pendingProvider, library: library).isEmpty)
        XCTAssertTrue(MobileSettingsRemovalChoices.mediaServer(pendingServer, media: media).isEmpty)
        XCTAssertEqual(library.profiles, [provider])
        XCTAssertEqual(media.profiles, [server])
        XCTAssertEqual(SportsLibrary(profileDefaults: defaults).profiles, [provider])
        XCTAssertEqual(MediaLibrary(defaults: defaults).profiles, [server])
    }

    private func waitForRemoval(_ profile: XtreamProfile, from library: SportsLibrary) async throws {
        let deadline = Date().addingTimeInterval(3)
        while (library.profiles.contains(profile) || library.isSwitchingProfile), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(library.profiles.contains(profile))
        XCTAssertFalse(library.isSwitchingProfile)
    }
}
