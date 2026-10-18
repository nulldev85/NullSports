import Foundation

/// The order of the Library's rows, as the viewer arranged them.
///
/// Rows come and go -- Continue Watching is gone while nothing is in it, a
/// shelf is added or taken away -- so the order is kept as a list of row ids
/// and laid over whatever rows there are, rather than as positions.
enum LibraryShelfOrder {
    // The rows kept on the device, which have no catalog of their own.
    static let collections = "collections"
    static let continueWatching = "continue-watching"
    static let favorites = "favorites"
    static let favoriteEpisodes = "favorite-episodes"

    /// `ids` in the order `saved` gives them. One `saved` does not name -- a
    /// shelf added since -- keeps its place in `ids`, just after the row it
    /// followed there: a new shelf arrives at the end, as it always has.
    static func arrange(_ ids: [String], by saved: [String]) -> [String] {
        guard !saved.isEmpty else { return ids }
        let present = Set(ids)
        var placed: Set<String> = []
        var result = saved.filter { present.contains($0) && placed.insert($0).inserted }
        for (index, id) in ids.enumerated() where !placed.contains(id) {
            var position = 0
            for earlier in ids[..<index].reversed() {
                if let found = result.firstIndex(of: earlier) {
                    position = found + 1
                    break
                }
            }
            result.insert(id, at: position)
            placed.insert(id)
        }
        return result
    }

    /// Rows in the saved order, by their ids.
    static func arranged<Row>(_ rows: [Row], id: (Row) -> String, by saved: [String]) -> [Row] {
        guard !saved.isEmpty else { return rows }
        var byID: [String: Row] = [:]
        for row in rows where byID[id(row)] == nil { byID[id(row)] = row }
        return arrange(rows.map(id), by: saved).compactMap { byID[$0] }
    }

    /// What to save once the viewer has moved rows: the rows on screen as
    /// they now stand, with any saved row not on screen -- an empty Continue
    /// Watching -- kept just after the row it followed before.
    static func saving(_ shown: [String], over saved: [String]) -> [String] {
        let known = Set(saved)
        return arrange(saved + shown.filter { !known.contains($0) }, by: shown)
    }

    /// `ids` with the one at `index` moved `step` places, kept in bounds.
    static func move(_ ids: [String], from index: Int, by step: Int) -> [String] {
        guard ids.indices.contains(index) else { return ids }
        let target = min(max(index + step, 0), ids.count - 1)
        guard target != index else { return ids }
        var moved = ids
        let id = moved.remove(at: index)
        moved.insert(id, at: target)
        return moved
    }
}
