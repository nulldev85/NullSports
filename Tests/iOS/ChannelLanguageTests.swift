import XCTest
@testable import LineupiOS

/// A game carried in English and in another language goes to the English
/// channel; the other is used only when it is all there is.
final class ChannelLanguageTests: XCTestCase {
    func testSpanishAndOtherLanguagesAreRecognised() {
        XCTAssertTrue(ChannelLanguage.isForeign(name: "ESPN Deportes", category: "US Sports"))
        XCTAssertTrue(ChannelLanguage.isForeign(name: "ES: NBA 01 Lakers vs Celtics", category: "NBA"))
        XCTAssertTrue(ChannelLanguage.isForeign(name: "[MX] FOX Sports", category: "Sports"))
        XCTAssertTrue(ChannelLanguage.isForeign(name: "NBA 01: Lakers vs Celtics", category: "LATINO | NBA"))
        XCTAssertTrue(ChannelLanguage.isForeign(name: "beIN SPORTS en Español", category: ""))
        XCTAssertTrue(ChannelLanguage.isForeign(name: "TUDN", category: ""))
        XCTAssertTrue(ChannelLanguage.isForeign(name: "Sky Sport 1", category: "DE | Sport"))
    }

    func testEnglishChannelsAreNot() {
        XCTAssertFalse(ChannelLanguage.isForeign(name: "ESPN", category: "US Sports"))
        XCTAssertFalse(ChannelLanguage.isForeign(name: "US: ESPN 2", category: "USA | SPORTS"))
        XCTAssertFalse(ChannelLanguage.isForeign(name: "NBA 01: Lakers vs Celtics", category: "NBA PASS"))
        XCTAssertFalse(ChannelLanguage.isForeign(name: "NFL: Bears vs Packers", category: "NFL Sunday Ticket"))
        XCTAssertFalse(ChannelLanguage.isForeign(name: "UK: Sky Sports Main Event", category: "UK Sports"))
        XCTAssertFalse(ChannelLanguage.isForeign(name: "TSN 1", category: "CA Sports"))
    }

    // English first whatever the evidence, then the stronger evidence, then
    // the provider's own order.
    func testEnglishComesFirstThenEvidenceThenOrder() {
        let foreign: Set<Int> = [1]
        XCTAssertTrue(SportsLibrary.ranksAhead((id: 2, score: 300), of: (id: 1, score: 400), foreign: foreign),
                      "An English channel whose guide lists the game beats a Spanish feed named for it")
        XCTAssertFalse(SportsLibrary.ranksAhead((id: 1, score: 400), of: (id: 2, score: 300), foreign: foreign))
        XCTAssertTrue(SportsLibrary.ranksAhead((id: 3, score: 400), of: (id: 2, score: 300), foreign: foreign))
        XCTAssertTrue(SportsLibrary.ranksAhead((id: 2, score: 300), of: (id: 3, score: 300), foreign: foreign))
    }
}
