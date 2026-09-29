import Foundation

extension AppDatabase {
    /// Saves in the background, after every write already queued (so
    /// changes land in the order they were made), then reports back on the
    /// main thread. Stores update what's on screen first, so the interface
    /// never waits for the disk.
    func writeInBackground<T: Sendable>(
        _ work: @escaping @Sendable (AppDatabase) throws -> T,
        then completion: @escaping @MainActor (Result<T, Error>) -> Void = { _ in }
    ) {
        perform(work) { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// Reads off the main thread (on the background reading connection).
    func readInBackground<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable (AppDatabase) throws -> T
    ) async throws -> T {
        let database = self
        return try await Task.detached(priority: priority) {
            try work(database)
        }.value
    }
}
