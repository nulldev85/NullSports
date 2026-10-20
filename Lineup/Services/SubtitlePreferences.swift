import Foundation

struct MobileSubtitlePreferences: Equatable {
    static let languageKey = "Lineup.subtitle.preferredLanguage.v1"
    static let sizeKey = "Lineup.subtitle.textScale.v1"
    static let backgroundKey = "Lineup.subtitle.background.v1"
    static let languages = [("", "Player Default"), ("en", "English"), ("es", "Spanish"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt-br", "Portuguese (Brazil)"),
        ("pt-pt", "Portuguese (Portugal)"), ("ja", "Japanese"), ("ko", "Korean"),
        ("ar", "Arabic"), ("hi", "Hindi"), ("zh-cn", "Chinese (Simplified)"), ("zh-tw", "Chinese (Traditional)")]
    static let sizes: [(Double, String)] = [(0.8, "Small"), (1, "Standard"), (1.25, "Large"), (1.5, "Extra Large")]
    var language = ""
    var scale: Double = 1
    var background = false

    init(defaults: UserDefaults = .standard) {
        let saved = defaults.string(forKey: Self.languageKey) ?? ""
        language = Self.languages.contains { $0.0 == saved } ? saved : ""
        let size = defaults.double(forKey: Self.sizeKey)
        scale = Self.sizes.contains { $0.0 == size } ? size : 1
        background = defaults.bool(forKey: Self.backgroundKey)
    }
    func save(to defaults: UserDefaults) {
        defaults.set(language, forKey: Self.languageKey)
        defaults.set(scale, forKey: Self.sizeKey)
        defaults.set(background, forKey: Self.backgroundKey)
        if !language.isEmpty { defaults.set(language, forKey: "Lineup.subtitles.language.v1") }
    }
    static func delay(_ seconds: Double) -> Double {
        seconds.isFinite ? min(30, max(-30, (seconds * 4).rounded() / 4)) : 0
    }
    var languageName: String { Self.languages.first { $0.0 == language }?.1 ?? "Player Default" }
    var sizeName: String { Self.sizes.first { $0.0 == scale }?.1 ?? "Standard" }
    /// Native metadata first. Do not infer a language from a release filename.
    static func matches(_ actual: String?, preferred: String) -> Bool {
        guard let actual, !preferred.isEmpty else { return false }
        func canonical(_ value: String) -> String {
            let value = value.lowercased().replacingOccurrences(of: "_", with: "-")
            let aliases = ["eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de",
                "ger": "de", "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko",
                "ara": "ar", "hin": "hi", "zho": "zh", "chi": "zh"]
            return aliases[value] ?? value
        }
        let normalizedActual = canonical(actual), normalizedPreferred = canonical(preferred)
        return normalizedActual == normalizedPreferred
            || (!normalizedActual.contains("-") && normalizedActual == normalizedPreferred.components(separatedBy: "-")[0])
    }
}
