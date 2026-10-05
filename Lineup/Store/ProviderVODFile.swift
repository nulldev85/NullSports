import Foundation

/// The IPTV provider's list as the device keeps it between launches: a line
/// per category and per title, its fields separated by tabs.
///
/// The list is read back at every launch before a title's VOD copies can be
/// looked for, so it is kept in the plainest form there is to read: split at
/// line breaks and tabs, and nothing else. Decoded as JSON, a provider's tens
/// of thousands of titles took seconds on an Apple TV, and the stream list's
/// VOD tab waited out every one of them.
enum ProviderVODFile {
    /// What a list read back holds: the catalog, and each title's filings in
    /// the catalog's order, worked out when the list was downloaded.
    struct Contents: Sendable {
        let catalog: ProviderVOD.Catalog
        let filmFilings: [[ProviderTitle.Filed]]
        let showFilings: [[ProviderTitle.Filed]]
    }

    /// The first line: what the file is, its layout, whose list it is, and
    /// when the provider sent it.
    private static let signature = "lineup-provider-vod"
    private static let version = "3"

    /// What the layout itself is made of, which a value has to escape.
    private static let reserved: Set<Unicode.Scalar> = ["\t", "\n", "\r", "\\"]

    // MARK: Writing

    static func encode(_ contents: Contents) -> Data {
        let catalog = contents.catalog
        var text = ""
        text.reserveCapacity((catalog.films.count + catalog.shows.count) * 160)
        func line(_ fields: [String]) {
            text += fields.joined(separator: "\t")
            text += "\n"
        }
        line([signature, version, catalog.profileID.uuidString,
              String(catalog.fetchedAt.timeIntervalSinceReferenceDate)])
        for group in catalog.filmCategories { line(["fc", field(group.categoryID), field(group.categoryName)]) }
        for group in catalog.showCategories { line(["sc", field(group.categoryID), field(group.categoryName)]) }
        for (film, filings) in zip(catalog.films, contents.filmFilings) {
            let fields: [String] = ["f", String(film.streamID), field(film.name), field(film.icon),
                                    field(film.categoryID), field(film.containerExtension),
                                    decimalField(film.rating), field(film.tmdbID), wholeField(film.year)]
            line(fields + filed(filings))
        }
        for (show, filings) in zip(catalog.shows, contents.showFilings) {
            let fields: [String] = ["s", String(show.seriesID), field(show.name), field(show.cover),
                                    field(show.plot), field(show.genre), decimalField(show.rating),
                                    field(show.backdrop), field(show.categoryID), field(show.tmdbID),
                                    wholeField(show.year)]
            line(fields + filed(filings))
        }
        return Data(text.utf8)
    }

    /// A value as written: nothing for none, and the characters the layout
    /// itself uses escaped -- a plot can run to several lines.
    private static func field(_ value: String?) -> String {
        guard let value else { return "" }
        guard value.unicodeScalars.contains(where: reserved.contains) else { return value }
        var escaped = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped.append(contentsOf: #"\\"#.unicodeScalars)
            case "\t": escaped.append(contentsOf: #"\t"#.unicodeScalars)
            case "\n": escaped.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": escaped.append(contentsOf: #"\r"#.unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        return String(escaped)
    }

    private static func wholeField(_ value: Int?) -> String { value.map { String($0) } ?? "" }
    private static func decimalField(_ value: Double?) -> String { value.map { String($0) } ?? "" }

    /// A title's filings, as a key and a year each, at the end of its line.
    private static func filed(_ filings: [ProviderTitle.Filed]) -> [String] {
        filings.flatMap { filing -> [String] in [field(filing.key), wholeField(filing.year)] }
    }

    // MARK: Reading

    /// The list, or nil when the file is not one this build wrote for this
    /// provider. A line that will not read is left out rather than losing the
    /// rest of the list with it.
    static func decode(_ data: Data, profileID: UUID) -> Contents? {
        data.withUnsafeBytes { raw -> Contents? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var position = 0
            var fields: [Range<Int>] = []
            fields.reserveCapacity(32)

            /// Moves on to the next line and finds its fields; false at the end.
            func nextLine() -> Bool {
                fields.removeAll(keepingCapacity: true)
                guard position < bytes.count else { return false }
                var start = position
                while position < bytes.count, bytes[position] != 0x0A {
                    if bytes[position] == 0x09 {
                        fields.append(start..<position)
                        start = position + 1
                    }
                    position += 1
                }
                fields.append(start..<position)
                position += 1
                return true
            }
            func text(_ index: Int) -> String {
                guard index < fields.count else { return "" }
                let value = String(decoding: UnsafeBufferPointer(rebasing: bytes[fields[index]]), as: UTF8.self)
                return value.utf8.contains(0x5C) ? unescaped(value) : value
            }
            func present(_ index: Int) -> String? {
                guard index < fields.count, !fields[index].isEmpty else { return nil }
                return text(index)
            }
            func integer(_ index: Int) -> Int? { present(index).flatMap { Int($0) } }
            func decimal(_ index: Int) -> Double? { present(index).flatMap { Double($0) } }
            func filings(from first: Int) -> [ProviderTitle.Filed] {
                stride(from: first, to: fields.count - 1, by: 2).map { index in
                    ProviderTitle.Filed(key: text(index), year: integer(index + 1))
                }
            }

            guard nextLine(), fields.count >= 4, text(0) == signature, text(1) == version,
                  UUID(uuidString: text(2)) == profileID, let seconds = decimal(3) else { return nil }
            var films: [XtreamVODStream] = []
            var shows: [XtreamSeries] = []
            var filmFilings: [[ProviderTitle.Filed]] = []
            var showFilings: [[ProviderTitle.Filed]] = []
            var filmCategories: [XtreamCategory] = []
            var showCategories: [XtreamCategory] = []
            while nextLine() {
                switch text(0) {
                case "f":
                    guard fields.count >= 9, let id = integer(1) else { continue }
                    films.append(XtreamVODStream(streamID: id, name: text(2), icon: present(3),
                                                 categoryID: present(4), containerExtension: present(5),
                                                 rating: decimal(6), tmdbID: present(7), year: integer(8)))
                    filmFilings.append(filings(from: 9))
                case "s":
                    guard fields.count >= 11, let id = integer(1) else { continue }
                    shows.append(XtreamSeries(seriesID: id, name: text(2), cover: present(3), plot: present(4),
                                              genre: present(5), rating: decimal(6), backdrop: present(7),
                                              categoryID: present(8), tmdbID: present(9), year: integer(10)))
                    showFilings.append(filings(from: 11))
                case "fc":
                    guard fields.count >= 3 else { continue }
                    filmCategories.append(XtreamCategory(categoryID: text(1), categoryName: text(2)))
                case "sc":
                    guard fields.count >= 3 else { continue }
                    showCategories.append(XtreamCategory(categoryID: text(1), categoryName: text(2)))
                default:
                    continue
                }
            }
            let catalog = ProviderVOD.Catalog(profileID: profileID, films: films, shows: shows,
                                              filmCategories: filmCategories, showCategories: showCategories,
                                              fetchedAt: Date(timeIntervalSinceReferenceDate: seconds))
            return Contents(catalog: catalog, filmFilings: filmFilings, showFilings: showFilings)
        }
    }

    private static func unescaped(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        var escaping = false
        for scalar in value.unicodeScalars {
            if escaping {
                switch scalar {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                default: result.append(scalar)
                }
                escaping = false
            } else if scalar == "\\" {
                escaping = true
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
