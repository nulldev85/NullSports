import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How much of a download has arrived, for a refresh's percentage.
struct XtreamDownloadUpdate: Sendable {
    let received: Int64
    /// The size the server gave, or nil when it did not say.
    let expected: Int64?
    /// The last word on a download: `received` is everything that came.
    let finished: Bool
}

/// The provider client supplies its session explicitly on both request paths.
/// Kept Foundation-only so CI can compile and exercise this before SDK builds.
enum XtreamDownload {
    typealias Progress = @MainActor @Sendable (XtreamDownloadUpdate) -> Void

    static func data(for request: URLRequest, session: URLSession,
                     progress: Progress?) async throws -> (Data, URLResponse) {
        guard let progress else { return try await session.data(for: request) }
        let watcher = XtreamDownloadWatcher()
        let ticker = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let counts = watcher.counts {
                    await progress(XtreamDownloadUpdate(received: counts.received,
                                                        expected: counts.expected > 0 ? counts.expected : nil,
                                                        finished: false))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let answer: (Data, URLResponse)
        do {
            answer = try await session.data(for: request, delegate: watcher)
        } catch {
            ticker.cancel()
            throw error
        }
        ticker.cancel()
        await ticker.value
        let received = watcher.counts?.received ?? Int64(answer.0.count)
        await progress(XtreamDownloadUpdate(received: received, expected: received, finished: true))
        return answer
    }
}

/// Samples byte counts instead of publishing each chunk of a large guide.
private final class XtreamDownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    var counts: (received: Int64, expected: Int64)? {
        lock.withLock {
            task.map { (received: $0.countOfBytesReceived, expected: $0.countOfBytesExpectedToReceive) }
        }
    }
}
