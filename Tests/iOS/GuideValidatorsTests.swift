import XCTest
@testable import LineupiOS

final class GuideValidatorsTests: XCTestCase {
    private func makeValidators() -> (GuideValidators, UserDefaults, String) {
        let suite = "GuideValidatorsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        return (GuideValidators(defaults: defaults), defaults, suite)
    }

    func testValidatorsAreKeptForTheGuideTheyCameWith() {
        let (validators, defaults, suite) = makeValidators()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://provider.invalid/xmltv.php?username=one&password=secret")!
        let entry = GuideValidators.Entry(digest: "abc", etag: "\"v1\"", lastModified: "Mon, 19 Oct 2026 09:00:00 GMT")
        validators.record(entry, for: url)
        XCTAssertEqual(validators.entry(for: url), entry)
        XCTAssertNil(validators.entry(for: URL(string: "https://other.invalid/guide.xml")!))
    }

    func testAServerWithoutValidatorsIsForgotten() {
        let (validators, defaults, suite) = makeValidators()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://provider.invalid/guide.xml")!
        validators.record(.init(digest: "abc", etag: "\"v1\"", lastModified: nil), for: url)
        validators.record(.init(digest: "def", etag: nil, lastModified: nil), for: url)
        XCTAssertNil(validators.entry(for: url))
    }

    func testTheAddressIsNotStoredInTheClear() {
        let (validators, defaults, suite) = makeValidators()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://provider.invalid/xmltv.php?username=one&password=secret")!
        validators.record(.init(digest: "abc", etag: "\"v1\"", lastModified: nil), for: url)
        let stored = String(decoding: defaults.data(forKey: GuideValidators.key) ?? Data(), as: UTF8.self)
        XCTAssertFalse(stored.contains("secret"))
        XCTAssertFalse(stored.contains("provider.invalid"))
    }
}
