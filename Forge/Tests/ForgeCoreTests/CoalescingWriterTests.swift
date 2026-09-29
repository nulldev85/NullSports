import Foundation
import XCTest
@testable import ForgeCore

final class CoalescingWriterTests: XCTestCase {
    /// Thread-safe record of what was written.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        private var failures: [Int] = []

        func append(_ value: Int) {
            lock.lock(); values.append(value); lock.unlock()
        }

        func fail(_ value: Int) {
            lock.lock(); failures.append(value); lock.unlock()
        }

        var written: [Int] {
            lock.lock(); defer { lock.unlock() }
            return values
        }

        var failed: [Int] {
            lock.lock(); defer { lock.unlock() }
            return failures
        }
    }

    func testFlushWritesWhatWasSubmitted() {
        let log = Log()
        let writer = CoalescingWriter<Int>(label: "test") { log.append($0) }
        writer.submit(1)
        writer.flush()
        XCTAssertEqual(log.written, [1])
        XCTAssertFalse(writer.hasPending)
    }

    func testBurstsAreCoalescedAndOrdered() {
        let log = Log()
        let writer = CoalescingWriter<Int>(label: "test") { value in
            Thread.sleep(forTimeInterval: 0.02)
            log.append(value)
        }
        for value in 1...50 {
            writer.submit(value)
        }
        writer.flush()
        let written = log.written
        XCTAssertEqual(written.last, 50, "the newest version always lands")
        XCTAssertLessThan(written.count, 50, "versions queued behind a running write are coalesced")
        XCTAssertEqual(written, written.sorted(), "writes never go back in time")
        XCTAssertEqual(Set(written).count, written.count)
    }

    func testInterleavedSubmitsStayOrdered() {
        let log = Log()
        let writer = CoalescingWriter<Int>(label: "test") { value in
            Thread.sleep(forTimeInterval: 0.001)
            log.append(value)
        }
        for value in 1...200 {
            writer.submit(value)
            if value % 7 == 0 { Thread.sleep(forTimeInterval: 0.002) }
        }
        writer.flush()
        XCTAssertEqual(log.written.last, 200)
        XCTAssertEqual(log.written, log.written.sorted())
    }

    func testDiscardPendingDropsQueuedVersions() {
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let writer = CoalescingWriter<Int>(label: "test") { value in
            if value == 1 {
                started.signal()
                gate.wait()
            }
            log.append(value)
        }
        writer.submit(1)
        started.wait()
        // Queued while the first write is still running.
        writer.submit(2)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
        writer.discardPending()
        XCTAssertEqual(log.written, [1], "the running write finishes before discardPending returns")
        writer.flush()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(log.written, [1], "the dropped version is never written")
    }

    func testCompletionReportsEachOutcome() {
        struct Failure: Error {}
        let log = Log()
        let writer = CoalescingWriter<Int>(label: "test") { value in
            if value == 2 { throw Failure() }
        }
        writer.onCompletion { value, error in
            if error == nil { log.append(value) } else { log.fail(value) }
        }
        writer.submit(1)
        writer.flush()
        writer.submit(2)
        writer.flush()
        writer.submit(3)
        writer.flush()
        XCTAssertEqual(log.written, [1, 3])
        XCTAssertEqual(log.failed, [2])
    }
}
