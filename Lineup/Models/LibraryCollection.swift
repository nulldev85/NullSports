import Foundation

/// A collection of the viewer's own: movies and shows from any server, kept
/// on this device as the original source-scoped items. It never touches a
/// server's own collections.
struct MobileLibraryCollection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [MediaItem] = []

    mutating func add(_ item: MediaItem) {
        guard ["Movie", "Series"].contains(item.type), !items.contains(where: { $0.libraryKey == item.libraryKey }) else { return }
        items.append(item.withMetadata(nil))
    }
}

extension MediaLibrary {
    @discardableResult
    func createCollection(named name: String, adding item: MediaItem? = nil) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { return nil }
        var collection = MobileLibraryCollection(name: name)
        if let item { collection.add(item) }
        personalCollections.append(collection)
        return collection.id
    }

    /// Whether a movie or show is in one of the viewer's collections.
    func isInCollection(_ item: MediaItem, _ id: UUID) -> Bool {
        personalCollections.first { $0.id == id }?.items.contains { $0.libraryKey == item.libraryKey } == true
    }

    /// Puts a title in a collection, or takes it out.
    func setInCollection(_ included: Bool, item: MediaItem, collection id: UUID) {
        guard let index = personalCollections.firstIndex(where: { $0.id == id }) else { return }
        if included { personalCollections[index].add(item) }
        else { personalCollections[index].items.removeAll { $0.libraryKey == item.libraryKey } }
    }
}
