import Foundation

/// Whether a channel broadcasts in another language than English.
///
/// A provider carries the same game more than once: ESPN beside ESPN Deportes,
/// an event feed under "US" and again under "ES" or "LATINO". The evidence for
/// both is the same -- a name or a listing naming the matchup -- so with no
/// preference the tie went to whichever the provider happened to list first,
/// and a provider that reshuffled its list put most of a night's games in
/// Spanish. An English channel now comes first wherever there is one; another
/// language is still used when it is the only one carrying the game.
enum ChannelLanguage {
    /// Words that name another language, or a country or service whose sports
    /// coverage is in one, wherever they appear in the name or the category.
    private static let foreignWords: Set<String> = [
        "deportes", "espanol", "spanish", "latino", "latina", "latinoamerica", "latam",
        "tudn", "univision", "unimas", "telemundo", "galavision",
        "mexico", "argentina", "colombia", "chile", "peru", "venezuela", "ecuador", "uruguay",
        "espana", "spain", "portugal", "portugues", "portuguese", "brasil", "brazil",
        "france", "french", "francais", "germany", "german", "deutsch", "deutschland",
        "italia", "italy", "italian", "arabic", "arabia", "turkiye", "turkish",
        "polska", "polish", "nederland", "dutch", "greek", "romania"
    ]

    /// The country and language codes providers put in front of a name or a
    /// category -- "ES: ESPN", "MX| SPORTS", "[LAT] FOX" -- that mean another
    /// language. Read only as such a prefix: "es" or "it" inside a name means
    /// nothing.
    private static let foreignCodes: Set<String> = [
        "es", "esp", "mx", "ar", "co", "cl", "pe", "ve", "ec", "uy", "lat", "latam", "latino",
        "br", "pt", "fr", "de", "it", "nl", "pl", "tr", "ru", "gr", "ro", "hu", "cz",
        "al", "ara", "arb", "exyu"
    ]

    static func isForeign(name: String, category: String) -> Bool {
        for text in [name, category] {
            if words(of: text).contains(where: foreignWords.contains) { return true }
            if let code = leadingCode(of: text), foreignCodes.contains(code) { return true }
        }
        return false
    }

    private static func words(of text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// A short code standing in front of the rest, set off by punctuation or
    /// brackets: "ES: ESPN", "ES | ESPN", "[ES] ESPN", "ES - ESPN", "EX-YU: ...".
    private static func leadingCode(of text: String) -> String? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        let bracketed = rest.first == "[" || rest.first == "("
        if bracketed { rest = rest.dropFirst() }
        let code = rest.prefix { $0.isLetter || $0 == "-" }
        guard (2...6).contains(code.count) else { return nil }
        let after = rest.dropFirst(code.count).drop { $0 == " " }
        guard let mark = after.first else { return nil }
        let separators: Set<Character> = [":", "|", "]", ")", "-", "•", "▶", "►", "»", "▎", "┃", "/"]
        guard separators.contains(mark) || (bracketed && mark == "]") else { return nil }
        return code.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
