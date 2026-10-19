import Foundation

@main
struct MobileTrackMemoryChecks {
    static func main() {
        // A show's next episode from the same release: the same names.
        let release = [MobileTrackOption(id: "a-1", title: "English · AC3", language: "eng", engineIndex: 1),
                       MobileTrackOption(id: "a-2", title: "English · Commentary · AAC", language: "eng", engineIndex: 2),
                       MobileTrackOption(id: "a-3", title: "Spanish · AC3", language: "spa", engineIndex: 3)]
        let commentary = MobileTrackMemory.choice(for: release[1])
        precondition(commentary == .init(title: "English · Commentary · AAC", language: "eng"))
        precondition(MobileTrackMemory.match(commentary, in: release)?.id == "a-2", "The same name comes first")

        // Another release: the language decides, by code, then by name.
        let other = [MobileTrackOption(id: "b-1", title: "Track 1 - [English]", language: nil),
                     MobileTrackOption(id: "b-2", title: "Track 2 - [Spanish]", language: nil)]
        let spanish = MobileTrackMemory.choice(for: release[2])
        precondition(MobileTrackMemory.match(spanish, in: other)?.id == "b-2", "A language's name is found in a track's")
        let coded = [MobileTrackOption(id: "c-1", title: "Audio 1", language: "en"),
                     MobileTrackOption(id: "c-2", title: "Audio 2", language: "es")]
        precondition(MobileTrackMemory.match(spanish, in: coded)?.id == "c-2", "spa is es")
        // A VLC name gives its language when the engine does not.
        precondition(MobileTrackMemory.choice(for: other[1]).language == "es")
        precondition(MobileTrackMemory.language(inTitle: "Audio 1") == nil)
        // Nothing to go on: the player's own choice stands.
        precondition(MobileTrackMemory.match(.init(title: "Director's Cut", language: nil), in: release) == nil)
        precondition(MobileTrackMemory.match(.init(title: "Japanese", language: "ja"), in: release) == nil)

        precondition(MobileTrackMemory.showKey(seriesName: "  The Bear ") == "the bear")
        precondition(MobileTrackMemory.showKey(seriesName: nil) == nil)
        precondition(MobileTrackMemory.showKey(seriesName: " ") == nil)

        // Kept per show, subtitles-off included, newest kept past the limit.
        let suite = "MobileTrackMemoryChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var kept = MobileShowTracks()
        kept.audio = spanish
        kept.subtitlesOff = true
        MobileTrackMemory.save(kept, for: "the bear", defaults: defaults)
        let read = MobileTrackMemory.load("the bear", defaults: defaults)
        precondition(read?.audio == spanish && read?.subtitlesOff == true && read?.hasSubtitleChoice == true)
        precondition(MobileTrackMemory.load("shogun", defaults: defaults) == nil)
        for show in 0..<(MobileTrackMemory.limit + 5) {
            MobileTrackMemory.save(MobileShowTracks(), for: "show \(show)", defaults: defaults)
        }
        precondition(MobileTrackMemory.load("the bear", defaults: defaults) == nil, "The oldest show goes first")
        precondition(MobileTrackMemory.load("show \(MobileTrackMemory.limit + 4)", defaults: defaults) != nil)
        print("Track memory checks passed")
    }
}
