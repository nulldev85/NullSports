import XCTest
@testable import LineupiOS

/// The playback log keeps the latest of what the player did, and keeps it
/// between launches, so a film that stopped on its own can be explained after
/// the fact.
@MainActor
final class PlaybackJournalTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "PlaybackJournalTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testItKeepsTheLatestEntriesAcrossLaunches() {
        let defaults = freshDefaults()
        let journal = PlaybackJournal(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(PlaybackJournal.limit + 5) {
            journal.note("Entry \(index)", at: start.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertEqual(journal.entries.count, PlaybackJournal.limit)
        XCTAssertEqual(journal.entries.first?.text, "Entry 5", "The oldest go first")
        XCTAssertEqual(journal.entries.last?.text, "Entry \(PlaybackJournal.limit + 4)")

        let relaunched = PlaybackJournal(defaults: defaults)
        XCTAssertEqual(relaunched.entries, journal.entries, "Read back as it was left")

        relaunched.clear()
        XCTAssertTrue(PlaybackJournal(defaults: defaults).entries.isEmpty)
    }

    func testAnExitWithoutLeavingTheScreenIsNamedAtTheNextLaunch() {
        let defaults = freshDefaults()
        let first = PlaybackJournal(defaults: defaults)
        first.appLaunched()
        first.note("Watching UFC 334 Gane vs. Hokit")
        // The app goes down here, still on screen, as a crash or tvOS ending
        // it for its memory would leave it.
        let second = PlaybackJournal(defaults: defaults)
        second.appLaunched()
        XCTAssertTrue(second.entries.contains {
            $0.text == "Lineup closed unexpectedly while watching UFC 334 Gane vs. Hokit"
        })
        // Sent to the background, then ended there by tvOS: nothing went wrong.
        second.appInFront(false)
        let third = PlaybackJournal(defaults: defaults)
        third.appLaunched()
        XCTAssertEqual(third.entries.filter { $0.text.contains("unexpectedly") }.count, 1)
        XCTAssertTrue(third.entries.last?.text.hasPrefix("Lineup opened") == true)
    }

    func testItListsTheNewestFirstUnderTheirDays() {
        let journal = PlaybackJournal(defaults: freshDefaults())
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        journal.note("Opened", at: morning)
        journal.note("Playing", at: morning.addingTimeInterval(60))
        journal.note("Next day", at: morning.addingTimeInterval(36 * 60 * 60))

        let days = journal.days
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.entries.map(\.text), ["Next day"])
        XCTAssertEqual(days.last?.entries.map(\.text), ["Playing", "Opened"])
    }

    func testAPlaceInAFilmReadsAsAClock() {
        XCTAssertEqual(PlaybackJournal.clock(0), "0:00")
        XCTAssertEqual(PlaybackJournal.clock(245), "4:05")
        XCTAssertEqual(PlaybackJournal.clock(3723), "1:02:03")
        XCTAssertEqual(PlaybackJournal.clock(-4), "0:00")
    }
}
