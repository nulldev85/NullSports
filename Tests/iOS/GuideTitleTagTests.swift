import XCTest
@testable import LineupiOS

/// Some guides tag a title in raised letters -- "The View ᴺᵉʷ". The tag comes
/// off the title, and a New one marks the programme new.
final class GuideTitleTagTests: XCTestCase {
    private func program(_ title: String) -> CurrentProgram {
        CurrentProgram(channelID: "1", title: title, detail: "", start: Date(), end: Date().addingTimeInterval(1800))
    }

    func testARaisedNewTagBecomesTheNewFlag() {
        let view = program("The View ᴺᵉʷ")
        XCTAssertEqual(view.title, "The View")
        XCTAssertEqual(view.isNew, true)
        XCTAssertEqual(program("KSEE24 Midday News  ᴺᵉʷ").title, "KSEE24 Midday News")
    }

    func testOtherRaisedTagsOnlyComeOff() {
        let live = program("NBA Basketball ᴸᶦᵛᵉ")
        XCTAssertEqual(live.title, "NBA Basketball")
        XCTAssertNil(live.isNew)
        XCTAssertEqual(program("Movie ᴴᴰ ᴺᵉʷ").title, "Movie")
        XCTAssertEqual(program("Movie ᴴᴰ ᴺᵉʷ").isNew, true)
    }

    func testOrdinaryTitlesAreUntouched() {
        XCTAssertEqual(program("E=mc²").title, "E=mc²")
        XCTAssertEqual(program("New Amsterdam").title, "New Amsterdam")
        XCTAssertNil(program("New Amsterdam").isNew)
        XCTAssertEqual(program("ᴺᵉʷ").title, "ᴺᵉʷ", "A title that is only a tag is left as it is")
    }

    func testSavedListingsAreCleanedAsTheyLoad() throws {
        let json = #"{"channelID":"1","title":"The View ᴺᵉʷ","detail":"","start":0,"end":1800}"#
        let saved = try JSONDecoder().decode(CurrentProgram.self, from: Data(json.utf8))
        XCTAssertEqual(saved.title, "The View")
        XCTAssertEqual(saved.isNew, true)
    }
}
