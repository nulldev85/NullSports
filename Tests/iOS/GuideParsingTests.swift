import XCTest
import zlib
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
            "20240229120000 +0000",   // a real leap day: 2024 is a leap year
            "20000229120000 +0000",   // a century that is a leap year
            "20250228235900 +0000",   // the last day of a February that has 28
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
            "20260918123000 +0000 trailing",
            // Days that do not exist. The arithmetic would roll these into the
            // following month; the formatters refused them, and so must this.
            "20260229120000 +0000",   // 2026 is not a leap year
            "19000229120000 +0000",   // nor is 1900, century or not
            "20260431120000 +0000",   // April has thirty days
            "20260900120000 +0000"    // and there is no zeroth
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

/// The guide draws an hour of history. Anything it can draw has to survive
/// parsing, or the first column reads "No listing" for every channel — which
/// is exactly what it did.
final class GuideRetentionTests: XCTestCase {
    func testParserKeepsEverythingTheGuideCanDraw() {
        // Whatever the clock, the parser must not discard earlier than the
        // guide's own window begins.
        for offset in stride(from: 0.0, to: 1800.0, by: 137.0) {
            let now = Date(timeIntervalSince1970: 1_800_000_000 + offset)
            XCTAssertLessThanOrEqual(XMLTVParser.retentionStart(now: now),
                                     MobileGuideWindow(now: now).start,
                                     "the parser drops listings the guide still shows at \(now)")
        }
    }

    func testAProgrammeThatEndedInTheLastHourIsStillParsed() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        // Ends twenty minutes ago: over, but still on screen in the lookback.
        let start = now.addingTimeInterval(-80 * 60)
        let end = now.addingTimeInterval(-20 * 60)
        let xml = """
        <tv><programme channel="c" start="\(formatter.string(from: start))" stop="\(formatter.string(from: end))">
        <title>Just Finished</title></programme></tv>
        """
        XCTAssertEqual(XMLTVParser(now: now).parse(Data(xml.utf8))["c"]?.first?.title, "Just Finished")
    }

    func testAProgrammeFromThisMorningIsStillDropped() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let start = now.addingTimeInterval(-6 * 3600)
        let end = now.addingTimeInterval(-5 * 3600)
        let xml = """
        <tv><programme channel="c" start="\(formatter.string(from: start))" stop="\(formatter.string(from: end))">
        <title>Long Over</title></programme></tv>
        """
        XCTAssertNil(XMLTVParser(now: now).parse(Data(xml.utf8))["c"])
    }
}

/// A guide read a programme at a time (`XMLTVParser.programs(fromGuide:)`):
/// the same listings as one whole parse when the guide is sound, and still
/// the listings when one of them is not.
final class GuideReadingTests: XCTestCase {
    /// Noon UTC, so "now" is well inside the window wherever the tests run.
    private let now = Date(timeIntervalSince1970: 1_789_732_800)  // 2026-09-18 12:00 UTC

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter.string(from: date)
    }

    private func programme(_ channel: String, at offset: TimeInterval, title: String, desc: String = "") -> String {
        let start = now.addingTimeInterval(offset)
        return "<programme start=\"\(stamp(start))\" stop=\"\(stamp(start.addingTimeInterval(1800)))\" channel=\"\(channel)\">"
            + "<title lang=\"en\">\(title)</title><desc>\(desc)</desc></programme>\n"
    }

    private func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CocoaError(.coderInvalidValue)
        }
        defer { deflateEnd(&stream) }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var status = Z_OK
            repeat {
                let produced: Int = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    status = deflate(&stream, Z_FINISH)
                    return buffer.count - Int(stream.avail_out)
                }
                output.append(contentsOf: chunk[0..<produced])
                guard status == Z_OK || status == Z_STREAM_END else { throw CocoaError(.coderInvalidValue) }
            } while status != Z_STREAM_END
        }
        return output
    }

    func testASoundGuideReadsAsOneWholeParseDoes() throws {
        // Over a megabyte, so listings straddle the pieces it arrives in, with
        // listings long past, far ahead and one written self-closing.
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE tv SYSTEM \"xmltv.dtd\">\n"
            + "<!-- made for a test -->\n<tv generator-info-name=\"test\">\n"
            + "<channel id=\"a\"><display-name>A</display-name></channel>\n"
        for index in 0..<6000 {
            let offset = TimeInterval((index % 200) - 40) * 1800
            xml += programme("ch\(index % 20)", at: offset, title: "Show \(index) &amp; Friends",
                             desc: "Episode \(index), padded out to a realistic length for a listing in a guide.")
        }
        xml += "<programme start=\"\(stamp(now))\" stop=\"\(stamp(now.addingTimeInterval(600)))\" channel=\"solo\"/>\n"
        xml += programme("far", at: 5 * 86_400, title: "Next Week")
        xml += "</tv>\n"
        let data = Data(xml.utf8)
        XCTAssertGreaterThan(data.count, 1 << 20)

        let whole = XMLTVParser(now: now)
        let expected = whole.parse(data)
        XCTAssertTrue(whole.isValid)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertNil(expected["far"], "Next week is outside the window")

        XCTAssertEqual(try XMLTVParser.programs(fromGuide: data, now: now), expected)
        XCTAssertEqual(try XMLTVParser.programs(fromGuide: try gzip(data), now: now), expected,
                       "A gzip guide reads the same as it unpacks")
    }

    func testABrokenListingCostsOnlyItself() throws {
        let xml = "<tv>\n"
            + programme("c", at: 0, title: "Law & Order", desc: "With&nbsp;guests &eacute;t&#233; \u{0B}live")
            + programme("c", at: 1800, title: "Kept")
            + programme("c", at: 3600, title: "1 < 2", desc: "Unrepairable markup")
            + programme("c", at: 5400, title: "Also Kept")
            + "</tv>"
        let data = Data(xml.utf8)

        let whole = XMLTVParser(now: now)
        _ = whole.parse(data)
        XCTAssertFalse(whole.isValid, "One strict parse gives up on the whole guide")

        let titles = try XMLTVParser.programs(fromGuide: data, now: now)["c"]?.map(\.title)
        XCTAssertEqual(titles, ["Law & Order", "Kept", "Also Kept"])
        let repaired = try XCTUnwrap(XMLTVParser.programs(fromGuide: data, now: now)["c"]?.first)
        XCTAssertEqual(repaired.detail, "With\u{00A0}guests été  live")
    }

    func testAGuideInAnotherEncodingIsNotRewrittenAsUTF8() throws {
        let body = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><tv>"
            + programme("c", at: 0, title: "Caf\u{E9}")
            + programme("c", at: 1800, title: "Caf\u{E9} & Bar")
            + "</tv>"
        let data = try XCTUnwrap(body.data(using: .isoLatin1))
        let titles = try XMLTVParser.programs(fromGuide: data, now: now)["c"]?.map(\.title)
        XCTAssertEqual(titles, ["Café", "Café & Bar"])
    }

    func testWhatIsNotAGuideStillFails() {
        XCTAssertThrowsError(try XMLTVParser.programs(fromGuide: Data(), now: now))
        XCTAssertThrowsError(try XMLTVParser.programs(fromGuide: Data("<!doctype html><html><body>Sign in</body></html>".utf8), now: now))
        XCTAssertEqual(try XMLTVParser.programs(fromGuide: Data("<tv></tv>".utf8), now: now), [:])
    }
}
