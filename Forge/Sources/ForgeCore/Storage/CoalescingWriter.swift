import Foundation

/// Persists the latest version of something that changes often (the workout
/// in progress) on a background queue, so saving never makes the interface
/// wait for the disk.
///
/// - Writes run one at a time, in order.
/// - Versions submitted while a write is running are coalesced: only the
///   newest one is written next.
/// - `flush()` returns once everything submitted is on disk. Call it before
///   the app leaves the foreground, and before a final write of your own so
///   nothing queued earlier can land after it.
public final class CoalescingWriter<Value: Sendable>: @unchecked Sendable {
    public typealias Completion = (Value, Error?) -> Void

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let write: (Value) throws -> Void
    private var pending: Value?
    private var drainScheduled = false
    private var completion: Completion?

    public init(label: String, write: @escaping (Value) throws -> Void) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.write = write
    }

    /// Called on the writer's queue after each write, with its error if it
    /// failed.
    public func onCompletion(_ completion: @escaping Completion) {
        lock.lock()
        self.completion = completion
        lock.unlock()
    }

    /// Queues `value` to be written, replacing any version still waiting.
    public func submit(_ value: Value) {
        lock.lock()
        pending = value
        let needsDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if needsDrain {
            queue.async { [self] in drain() }
        }
    }

    /// Writes anything still queued and waits for it (and any write already
    /// running) to finish. Never call it from the completion handler.
    public func flush() {
        queue.sync { drain() }
    }

    /// Drops versions that haven't started writing, then waits for a write
    /// already running to finish.
    public func discardPending() {
        lock.lock()
        pending = nil
        lock.unlock()
        queue.sync {}
    }

    /// True while a version is waiting to be written.
    public var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    private func drain() {
        lock.lock()
        let value = pending
        pending = nil
        drainScheduled = false
        let completion = completion
        lock.unlock()
        guard let value else { return }
        do {
            try write(value)
            completion?(value, nil)
        } catch {
            completion?(value, error)
        }
    }
}
