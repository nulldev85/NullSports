import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class UFCScheduleTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "ufc333-live",
            withExtension: "json", subdirectory: "Fixtures")))
    }
    private func changingCard(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var events = try XCTUnwrap(root["events"] as? [[String: Any]])
        var card = try XCTUnwrap(events.first)
        change(&card)
        events[0] = card; root["events"] = events
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func status(_ state: String, _ detail: String) -> [String: Any] {
        ["type": ["state": state, "description": detail, "shortDetail": detail]]
    }
    private func game(_ data: Data) throws -> SportsGame {
        try XCTUnwrap(SportsScheduleClient.ufcGames(data: data).first)
    }

    func testLiveCardWithCompletedPrelimsUsesEventStatusAndHeadlineFighters() throws {
        let card = try game(fixture())
        XCTAssertEqual(card.id, "ufc-600061267")
        XCTAssertEqual(card.eventName, "UFC 333: Volkanovski vs. Evloev")
        XCTAssertEqual(card.state, "in")
        XCTAssertEqual(card.status, "In Progress")
        XCTAssertTrue(card.isLive)
        XCTAssertFalse(card.isUpcoming)
        XCTAssertEqual(Set([card.awayTeam, card.homeTeam]), ["Alexander Volkanovski", "Movsar Evloev"])
        XCTAssertTrue(card.isEvent)
    }

    func testFinishingPrelimsAndChangingBoutOrderCannotEndTheCard() throws {
        for reversed in [false, true] {
            let data = try changingCard { card in
                var bouts = card["competitions"] as! [[String: Any]]
                for index in bouts.indices { bouts[index]["status"] = status("post", "Final") }
                if reversed { bouts.reverse() }
                card["competitions"] = bouts
            }
            let card = try game(data)
            XCTAssertEqual(card.id, "ufc-600061267")
            XCTAssertEqual(card.state, "in", "The card's live status is authoritative")
            XCTAssertTrue(card.isLive)
            XCTAssertEqual(Set([card.awayTeam, card.homeTeam]), ["Alexander Volkanovski", "Movsar Evloev"])
        }
    }

    func testExplicitCardFinalEndsEventEvenWithStaleScheduledBouts() throws {
        let data = try changingCard { $0["status"] = status("post", "Final") }
        let card = try game(data)
        XCTAssertEqual(card.state, "post")
        XCTAssertEqual(card.status, "Final")
        XCTAssertFalse(card.isLive)
        XCTAssertFalse(card.isUpcoming)
    }

    func testCanceledCardPreservesExplicitCardStatus() throws {
        let card = try game(changingCard { $0["status"] = status("post", "Canceled") })
        XCTAssertEqual(card.status, "Canceled")
        XCTAssertFalse(card.isLive)
        XCTAssertFalse(card.isUpcoming)
    }

    func testMissingCardStatusUsesAllBoutsWhileBetweenFights() throws {
        let card = try game(changingCard {
            $0.removeValue(forKey: "status")
            $0["date"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
            var bouts = $0["competitions"] as! [[String: Any]]
            for index in bouts.indices { bouts[index]["status"] = status(index == 0 ? "post" : "pre", index == 0 ? "Final" : "Scheduled") }
            $0["competitions"] = bouts
        })
        XCTAssertEqual(card.state, "pre")
        XCTAssertTrue(card.isLive, "The existing card start-time fallback covers the gap between bouts")
    }

    func testMissingCardStatusWithEveryBoutFinalEndsTheCard() throws {
        let card = try game(changingCard {
            $0.removeValue(forKey: "status")
            var bouts = $0["competitions"] as! [[String: Any]]
            for index in bouts.indices { bouts[index]["status"] = status("post", "Final") }
            $0["competitions"] = bouts
        })
        XCTAssertEqual(card.state, "post")
        XCTAssertFalse(card.isLive)
        XCTAssertFalse(card.isUpcoming)
    }

    func testActiveBoutCanAdvanceLaggingScheduledCardStatus() throws {
        let card = try game(changingCard {
            $0["status"] = status("pre", "Scheduled")
            var bouts = $0["competitions"] as! [[String: Any]]
            bouts[1]["status"] = status("in", "Round 2")
            $0["competitions"] = bouts
        })
        XCTAssertEqual(card.state, "in")
        XCTAssertEqual(card.status, "In Progress", "A round's status is not the card's status text")
        XCTAssertTrue(card.isLive)
    }

    func testMissingBoutStatusCannotMakePartialResultsLookLikeAFinalCard() throws {
        let card = try game(changingCard {
            $0.removeValue(forKey: "status")
            $0["date"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
            var bouts = $0["competitions"] as! [[String: Any]]
            for index in bouts.indices { bouts[index]["status"] = status("post", "Final") }
            bouts[0].removeValue(forKey: "status")
            $0["competitions"] = bouts
        })
        XCTAssertEqual(card.state, "pre")
        XCTAssertTrue(card.isLive)
    }

    func testFutureCardRemainsUpcomingAndNumberedHeadlinerStillWorks() throws {
        let card = try game(changingCard {
            $0["status"] = status("pre", "Scheduled")
            $0["date"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            var bouts = $0["competitions"] as! [[String: Any]]
            for index in bouts.indices {
                bouts[index]["status"] = status("pre", "Scheduled")
                bouts[index]["matchNumber"] = bouts.count - index
            }
            $0["competitions"] = bouts
        })
        XCTAssertEqual(card.state, "pre")
        XCTAssertTrue(card.isUpcoming)
        XCTAssertFalse(card.isLive)
        XCTAssertEqual(Set([card.awayTeam, card.homeTeam]), ["Alexander Volkanovski", "Movsar Evloev"])
    }

    func testMalformedScheduleIsAnErrorAndLegitimateEmptyDayIsEmpty() throws {
        XCTAssertThrowsError(try SportsScheduleClient.ufcGames(data: Data(#"{"error":"unavailable"}"#.utf8)))
        XCTAssertTrue(try SportsScheduleClient.ufcGames(data: Data(#"{"events":[]}"#.utf8)).isEmpty)
    }
}
