import Foundation

@main
struct MobileSubtitlePreferenceChecks {
    static func main() {
        // Compile the production helper, including its real language matcher,
        // before dependency resolution and the full Apple SDK suite.
        precondition(MobileSubtitlePreferences.matches("eng", preferred: "en"))
        precondition(MobileSubtitlePreferences.matches("POR", preferred: "pt-br"))
        precondition(MobileSubtitlePreferences.matches("pt_BR", preferred: "pt-br"))
        precondition(!MobileSubtitlePreferences.matches("pt-pt", preferred: "pt-br"))
        precondition(!MobileSubtitlePreferences.matches(nil, preferred: "en"))
        precondition(!MobileSubtitlePreferences.matches("eng", preferred: ""))
        precondition(MobileSubtitlePreferences.delay(0.38) == 0.5)
        precondition(MobileSubtitlePreferences.delay(-100) == -30)
        precondition(MobileSubtitlePreferences.delay(100) == 30)
        precondition(MobileSubtitlePreferences.delay(.nan) == 0)
        let suite = "MobileSubtitlePreferenceChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid-language", forKey: MobileSubtitlePreferences.languageKey)
        defaults.set(70, forKey: MobileSubtitlePreferences.sizeKey)
        var preferences = MobileSubtitlePreferences(defaults: defaults)
        precondition(preferences.language == "" && preferences.scale == 1)
        preferences.language = "es"; preferences.scale = 1.5; preferences.background = true
        preferences.save(to: defaults)
        precondition(MobileSubtitlePreferences(defaults: defaults) == preferences)
        precondition(defaults.string(forKey: "Lineup.subtitles.language.v1") == "es")
        print("Subtitle preference checks passed")
    }
}
