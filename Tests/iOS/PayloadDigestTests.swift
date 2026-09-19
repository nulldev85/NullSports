
/// Reading a server address the way somebody types one.
final class JellyfinAddressTests: XCTestCase {
    private func host(_ typed: String) -> String? {
        JellyfinClient.address(from: typed)?.absoluteString
    }

    // The case that sent this back. On a television nobody types a scheme, and
    // without one URL reads the host itself as the scheme and the whole thing
    // is rejected as unreadable.
    func testAHostAndPortIsAnAddress() {
        XCTAssertEqual(host("192.168.1.50:8096"), "http://192.168.1.50:8096")
        XCTAssertEqual(host("media.local:8096"), "http://media.local:8096")
        XCTAssertEqual(host("jellyfin.example.com"), "http://jellyfin.example.com")
    }

    func testAFullAddressIsLeftAlone() {
        XCTAssertEqual(host("https://media.example.com"), "https://media.example.com")
        XCTAssertEqual(host("http://192.168.1.50:8096"), "http://192.168.1.50:8096")
    }

    // Trailing slashes and stray spaces come free with an on-screen keyboard.
    func testItForgivesSlashesAndSpaces() {
        XCTAssertEqual(host("  https://media.example.com/  "), "https://media.example.com")
        XCTAssertEqual(host("192.168.1.50:8096/"), "http://192.168.1.50:8096")
    }

    func testNothingIsNotAnAddress() {
        XCTAssertNil(host(""))
        XCTAssertNil(host("   "))
    }
}
