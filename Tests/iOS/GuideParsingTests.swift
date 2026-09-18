import XCTest
@testable import LineupiOS

/// The timestamp reader replaced three DateFormatters. These check it against
/// those same formatters rather than against hand-written expectations, so the
/// test is the equivalence claim itself: whatever the old path accepted and
/// whatever date it produced, this produces too.
final class GuideParsingTests: XCTestCase {
    private func reference(_ value: String) -> Date? {
        for format in ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmm Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    func testTimestampMatchesTheFormattersItReplaced() {
        let samples = [
            "20260918123000 +0000",
            "20260918123000+0000",
            "202609181230 +0000",
            "20260918123000 -0500",
            "20260918123000-0930",
            "20260101000000 +0100",
            "20261231235959 +0000",
            "20260229120000 +0000",   // a leap day
            "20250228235900 +0000",   // the day before one that does not exist
            "20260630120000 +0530",
            "19700101000000 +0000",   // the epoch itself
            "19691231235959 +0000"    // and just before it
        ]
        for sample in samples {
            XCTAssertEqual(XMLTVParser.timestamp(sample), reference(sample),
                           "disagreed on \(sample)")
        }
    }

    func testRejectsWhatTheFormattersRejected() {
        let rubbish = [
            "", "not a date", "2026091812300", "20260918123000",
            "20260918123000 0000", "20260918", "20261318123000 +0000",
            "20260918253000 +0000", "20260918126000 +0000",
            "20260918123000 +0000 trailing"
        ]
        for sample in rubbish {
            XCTAssertNil(XMLTVParser.timestamp(sample), "accepted \(sample)")
            XCTAssertNil(reference(sample), "the reference accepted \(sample)")
        }
    }

    func testParsesAProgrammeIntoItsChannel() {
        let start = Date().addingTimeInterval(600)
        let end = start.addingTimeInterval(3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let xml = """
        <tv><programme channel="sky.uk" start="\(formatter.string(from: start))" stop="\(formatter.string(from: end))">
        <title>The Match</title><desc>Coverage</desc></programme></tv>
        """
        let parsed = XMLTVParser().parse(Data(xml.utf8))
        XCTAssertEqual(parsed["sky.uk"]?.count, 1)
        XCTAssertEqual(parsed["sky.uk"]?.first?.title, "The Match")
        XCTAssertEqual(parsed["sky.uk"]?.first?.detail, "Coverage")
    }

    /// The dedupe carries the previous trimmed title rather than recomputing
    /// it, so these cover the paths where the tail changes underneath it.
    func testDedupeStillMergesRepeatsAndTrimsOverlap() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func program(_ title: String, _ from: TimeInterval, _ to: TimeInterval) -> CurrentProgram {
            CurrentProgram(channelID: "c", title: title, detail: "",
                           start: base.addingTimeInterval(from), end: base.addingTimeInterval(to),
                           isNew: false)
        }
        // A repeat of the same listing, spelled differently, merges into one.
        let merged = [program("The Match", 0, 3600), program("  the match ", 3600, 7200)].normalizedEPG()
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.end, base.addingTimeInterval(7200))

        // A different title that starts early clips the one before it.
        let clipped = [program("First", 0, 3600), program("Second", 1800, 5400)].normalizedEPG()
        XCTAssertEqual(clipped.count, 2)
        XCTAssertEqual(clipped.first?.end, base.addingTimeInterval(1800))
        XCTAssertEqual(clipped.last?.title, "Second")

        // An untitled listing takes the title of the one it merges with.
        let named = [program("", 0, 3600), program("Named", 1800, 5400)].normalizedEPG()
        XCTAssertEqual(named.count, 2)
    }
}
