import XCTest
@testable import LineupiOS

/// The digest is the whole basis of the cheap path: if it says the bytes are
/// the ones already in hand, the app skips decoding them, comparing them and
/// writing them. It has to be exact about that, and it has to mean the same
/// thing on the next launch as it did on this one.
final class PayloadDigestTests: XCTestCase {
    private func digest(_ text: String) -> String {
        XtreamPayloadDigest.of(Data(text.utf8))
    }

    func testTheSameBytesAlwaysGiveTheSameDigest() {
        XCTAssertEqual(digest("<tv><programme/></tv>"), digest("<tv><programme/></tv>"))
    }

    // Not a Swift hashValue, which is seeded per process: a digest written to
    // the cache on one launch has to still mean something on the next.
    func testTheDigestIsALiteralValueRatherThanAProcessHash() {
        // SHA-256 of the empty input, which is the same everywhere or it is
        // not SHA-256.
        XCTAssertEqual(XtreamPayloadDigest.of(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testADifferentByteGivesADifferentDigest() {
        XCTAssertNotEqual(digest("channel 1"), digest("channel 2"))
        XCTAssertNotEqual(digest("abc"), digest("abd"))
        // Order matters: a server that reorders a list has changed the bytes,
        // which is why a digest miss still falls through to the real compare.
        XCTAssertNotEqual(digest("[a,b]"), digest("[b,a]"))
    }

    func testAnEmptyAnswerIsNotTheSameAsAMissingOne() {
        XCTAssertNotEqual(XtreamPayloadDigest.of(Data()), digest("[]"))
    }
}

/// Which of the three cache files a refresh has to rewrite, and when the app
/// has earned the right to ask the server the cheap question.
final class LibraryCachePolicyTests: XCTestCase {
    private func channels(categories: String? = "c1", streams: String? = "s1",
                          guide: String? = "g1", index: Bool = true) -> String {
        LibraryCachePolicy.channelsSignature(categoriesDigest: categories, streamsDigest: streams,
                                             guideDigest: guide, hasIndex: index)
    }

    // The point of the split: a refresh that finds everything unchanged still
    // has new timestamps and new matches to record, and those live in a file
    // small enough that writing it costs nothing. The channel list and the
    // day of listings beside it stay where they are.
    func testAnUnchangedRefreshRewritesNeitherBigFile() {
        let written = channels()
        XCTAssertFalse(LibraryCachePolicy.needsWriting(signature: channels(), lastWritten: written))
        XCTAssertFalse(LibraryCachePolicy.needsWriting(
            signature: LibraryCachePolicy.guideSignature(guideDigest: "g1"), lastWritten: "g1"))
    }

    func testANewChannelListRewritesTheChannelFile() {
        XCTAssertTrue(LibraryCachePolicy.needsWriting(
            signature: channels(streams: "s2"), lastWritten: channels()))
    }

    // The index is built from the channels and the guide, so a new guide
    // means a new index, which lives in the channel file.
    func testANewGuideRewritesBothFiles() {
        XCTAssertTrue(LibraryCachePolicy.needsWriting(
            signature: channels(guide: "g2"), lastWritten: channels()))
        XCTAssertTrue(LibraryCachePolicy.needsWriting(
            signature: LibraryCachePolicy.guideSignature(guideDigest: "g2"), lastWritten: "g1"))
    }

    // A launch that restored a stale index rebuilds one, and the rebuilt index
    // is worth keeping even though nothing it was built from changed.
    func testAnIndexArrivingRewritesTheChannelFile() {
        XCTAssertTrue(LibraryCachePolicy.needsWriting(
            signature: channels(index: true), lastWritten: channels(index: false)))
    }

    // Nothing written yet is not "nothing to write".
    func testAFirstWriteAlwaysHappens() {
        XCTAssertTrue(LibraryCachePolicy.needsWriting(signature: channels(), lastWritten: nil))
    }

    // Missing digests are a signature of their own, not a match for a real one.
    func testAbsentDigestsDoNotCollideWithPresentOnes() {
        XCTAssertNotEqual(channels(categories: nil), channels(categories: "c1"))
        XCTAssertNotEqual(channels(guide: nil), channels(guide: "g1"))
        XCTAssertNotEqual(LibraryCachePolicy.guideSignature(guideDigest: nil),
                          LibraryCachePolicy.guideSignature(guideDigest: "g1"))
    }
}

/// Asking "tell me only if this changed" while holding nothing is how an app
/// ends up empty with no way to ask again.
final class LibraryCacheDigestQuestionTests: XCTestCase {
    func testADigestIsSentOnlyWhenWhatItDescribesIsInHand() {
        XCTAssertEqual(LibraryCachePolicy.digest("s1", whenHolding: true), "s1")
        XCTAssertNil(LibraryCachePolicy.digest("s1", whenHolding: false),
                     "A cache file that went missing must produce a plain fetch, not a no-op")
    }

    func testNothingRememberedMeansNothingAsked() {
        XCTAssertNil(LibraryCachePolicy.digest(nil, whenHolding: true))
        XCTAssertNil(LibraryCachePolicy.digest(nil, whenHolding: false))
    }
}
