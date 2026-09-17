import Foundation

/// Recently watched channels, as a plain ordered list of provider stream IDs.
///
/// Scoped to one provider by the caller's storage key, exactly like favorites
/// and team preferences: a channel identifier only means something inside the
/// provider that issued it.
enum RecentChannels {
    /// Enough to be useful in a menu without becoming a second guide.
    static let limit = 15

    /// Most recent first, no duplicates, capped. Re-watching a channel moves it
    /// to the front rather than adding a second entry.
    static func updated(_ list: [Int], watching streamID: Int, limit: Int = limit) -> [Int] {
        guard limit > 0 else { return [] }
        var updated = list.filter { $0 != streamID }
        updated.insert(streamID, at: 0)
        return Array(updated.prefix(limit))
    }

    /// Drops entries the provider no longer carries.
    ///
    /// Applied when reading, never when writing: a channel that disappears from
    /// one refresh and returns in the next keeps its place in the list, but can
    /// never be played from a stale entry in the meantime.
    static func resolved(_ list: [Int], available: Set<Int>) -> [Int] {
        list.filter { available.contains($0) }
    }
}
