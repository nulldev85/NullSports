import Foundation

/// A track as the player offers it: its own id, the name it shows, and its
/// language where the engine knows one.
struct MobileTrackOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let language: String?
    /// What choosing it sets in the engine: Aether's and VLC's own index.
    var engineIndex: Int? = nil
}

/// The sound and subtitles a viewer chose for a show, put back on its next
/// episode.
///
/// A show's episodes almost always come from one release, which names its
/// tracks the same way every time, so the track is found again by its name
/// first -- "English · AC3 5.1" is not "English · Commentary". A different
/// release names them differently, and then the language decides.
struct MobileShowTracks: Codable, Equatable, Sendable {
    struct Choice: Codable, Equatable, Sendable {
        var title: String
        var language: String?
    }

    var audio: Choice?
    var subtitle: Choice?
    /// Subtitles turned off is a choice too, and it is kept.
    var subtitlesOff = false
    var savedAt = Date()

    var hasSubtitleChoice: Bool { subtitlesOff || subtitle != nil }
}

enum MobileTrackMemory {
    static let key = "Lineup.player.showTracks.v1"
    /// Shows kept, the most recently watched first.
    static let limit = 200

    /// The key a show is kept under: its name, so the same show on another
    /// server, or from the provider's catalog, is the same show.
    static func showKey(seriesName: String?) -> String? {
        let name = (seriesName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? nil : name
    }

    static func load(_ show: String, defaults: UserDefaults = .standard) -> MobileShowTracks? {
        all(defaults)[show]
    }

    static func save(_ tracks: MobileShowTracks, for show: String, defaults: UserDefaults = .standard) {
        var kept = all(defaults)
        var tracks = tracks
        tracks.savedAt = Date()
        kept[show] = tracks
        if kept.count > limit {
            let oldest = kept.sorted { $0.value.savedAt > $1.value.savedAt }.dropFirst(limit).map(\.key)
            for key in oldest { kept.removeValue(forKey: key) }
        }
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: key) }
    }

    private static func all(_ defaults: UserDefaults) -> [String: MobileShowTracks] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: MobileShowTracks].self, from: $0) } ?? [:]
    }

    /// What is kept of a track: its name, and its language -- the engine's
    /// own, or one its name gives.
    static func choice(for track: MobileTrackOption) -> MobileShowTracks.Choice {
        .init(title: track.title, language: track.language.flatMap { $0.isEmpty ? nil : $0 } ?? language(inTitle: track.title))
    }

    /// The track among `tracks` a kept choice answers to: the same name,
    /// then the same language by the engine's code, then by the language's
    /// name in a track's own name. Nil when none does: the player's own
    /// choice stands rather than a guess.
    static func match(_ choice: MobileShowTracks.Choice, in tracks: [MobileTrackOption]) -> MobileTrackOption? {
        let wanted = normalized(choice.title)
        if let same = tracks.first(where: { normalized($0.title) == wanted }) { return same }
        guard let language = choice.language, !language.isEmpty else { return nil }
        if let coded = tracks.first(where: { MobileSubtitlePreferences.matches($0.language, preferred: language) }) {
            return coded
        }
        let names = languageNames(language)
        return tracks.first { track in
            let words = Set(normalized(track.title).components(separatedBy: CharacterSet.letters.inverted))
            return names.contains { words.contains($0) }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The languages a track's name most often gives instead of a code --
    /// VLC's "Track 2 - [Spanish]" -- by their English and their own names.
    private static let namedLanguages: [(code: String, names: [String])] = [
        ("en", ["english"]), ("es", ["spanish", "español", "espanol", "castellano"]),
        ("fr", ["french", "français", "francais"]), ("de", ["german", "deutsch"]),
        ("it", ["italian", "italiano"]), ("pt", ["portuguese", "português", "portugues"]),
        ("ja", ["japanese", "日本語"]), ("ko", ["korean", "한국어"]), ("zh", ["chinese", "mandarin", "cantonese", "中文"]),
        ("ar", ["arabic", "العربية"]), ("hi", ["hindi"]), ("ru", ["russian", "русский"]),
        ("nl", ["dutch", "nederlands"]), ("sv", ["swedish", "svenska"]), ("no", ["norwegian", "norsk"]),
        ("da", ["danish", "dansk"]), ("fi", ["finnish", "suomi"]), ("pl", ["polish", "polski"]),
        ("tr", ["turkish", "türkçe"]), ("el", ["greek"]), ("he", ["hebrew"]), ("th", ["thai"]),
        ("vi", ["vietnamese"]), ("cs", ["czech"]), ("hu", ["hungarian"]), ("ro", ["romanian"]),
        ("uk", ["ukrainian"]), ("id", ["indonesian"])
    ]

    static func language(inTitle title: String) -> String? {
        let words = Set(normalized(title).components(separatedBy: CharacterSet.letters.inverted))
        return namedLanguages.first { $0.names.contains(where: words.contains) }?.code
    }

    private static func languageNames(_ code: String) -> [String] {
        let base = code.lowercased().replacingOccurrences(of: "_", with: "-").components(separatedBy: "-")[0]
        let aliases = ["eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "ita": "it",
                       "por": "pt", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh", "ara": "ar", "hin": "hi",
                       "rus": "ru", "nld": "nl", "dut": "nl", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi",
                       "pol": "pl", "tur": "tr", "ell": "el", "gre": "el", "heb": "he", "tha": "th", "vie": "vi",
                       "ces": "cs", "cze": "cs", "hun": "hu", "ron": "ro", "rum": "ro", "ukr": "uk", "ind": "id"]
        let canonical = aliases[base] ?? base
        var names = namedLanguages.first { $0.code == canonical }?.names ?? []
        for locale in [Locale(identifier: "en"), Locale.current] {
            if let name = locale.localizedString(forLanguageCode: canonical)?.lowercased(), !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}
