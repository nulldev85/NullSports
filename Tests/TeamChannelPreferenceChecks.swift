import Foundation

@main
struct TeamChannelPreferenceChecks {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }

        let game = TeamChannelGame(league: "nfl", homeTeam: "Kansas City Chiefs", homeAbbreviation: "KC",
                                   awayTeam: "Buffalo Bills", awayAbbreviation: "BUF")
        let espn = 101, fox = 202, regional = 303, verified = 999
        let carried: Set<Int> = [espn, fox, regional, verified]
        let withoutESPNEarly: Set<Int> = [fox, regional, verified]

        func pref(_ id: Int, _ name: String, _ team: String, at seconds: TimeInterval = 0) -> TeamChannelPreference {
            TeamChannelPreference(streamID: id, channelName: name, teamName: team,
                                  savedAt: Date(timeIntervalSince1970: seconds))
        }

        // Keys -------------------------------------------------------------
        check(game.homeKey.storageKey == "NFL|KC", "League and abbreviation form the key")
        check(TeamChannelKey(league: "nfl", abbreviation: " kc ", name: "x").storageKey == "NFL|KC",
              "Keys normalize case and padding")
        check(TeamChannelKey(league: "ufc", abbreviation: "", name: "Jon  Jones").storageKey == "UFC|JON JONES",
              "An empty abbreviation falls back to the normalized name")
        check(!TeamChannelKey(league: "nfl", abbreviation: "", name: "").isUsable,
              "A key with no team at all is not usable")
        // A renamed team keeps its key, which is the point of not using names.
        check(TeamChannelKey(league: "nfl", abbreviation: "KC", name: "Kansas City Chiefs")
              == TeamChannelKey(league: "nfl", abbreviation: "KC", name: "KC Chiefs"),
              "A display-name change does not orphan a preference")

        // Persistence round trip -------------------------------------------
        var store = TeamChannelPreferences()
        store.set(pref(espn, "ESPN", "Kansas City Chiefs"), for: game.homeKey)
        let encoded = try! JSONEncoder().encode(store)
        let decoded = try! JSONDecoder().decode(TeamChannelPreferences.self, from: encoded)
        check(decoded == store, "A store survives an encode/decode round trip")
        check(decoded.preference(for: game.homeKey)?.streamID == espn, "The channel identifier persists")
        check(decoded.preference(for: game.awayKey) == nil, "Only the saved team has a preference")
        check(store.count == 1, "One team, one entry")
        var unusable = TeamChannelPreferences()
        unusable.set(pref(espn, "ESPN", ""), for: TeamChannelKey(league: "nfl", abbreviation: "", name: ""))
        check(unusable.isEmpty, "An unusable key is never stored")

        // Automatic use ----------------------------------------------------
        check(store.resolve(game, matchingReady: true, availableStreamIDs: carried,
                            verifiedStreamID: verified) == .play(streamID: espn, source: .homePreference),
              "A saved, available preference is used without asking")
        // A saved preference is the viewer's own choice and needs no matching
        // evidence, so it plays straight from restored cache — this is what
        // makes a repeat launch usable before the network pass finishes.
        check(store.resolve(game, matchingReady: false, availableStreamIDs: carried,
                            verifiedStreamID: verified) == .play(streamID: espn, source: .homePreference),
              "A saved preference does not wait for channel matching")
        check(store.resolve(game, matchingReady: false, availableStreamIDs: withoutESPNEarly,
                            verifiedStreamID: verified) == .syncing,
              "With no usable preference, an unfinished index still reports syncing")
        check(TeamChannelPreferences().resolve(game, matchingReady: true, availableStreamIDs: carried,
                                               verifiedStreamID: verified) == .pick,
              "With nothing saved the viewer picks, even when Lineup has a match")
        check(TeamChannelPreferences().resolve(game, matchingReady: false, availableStreamIDs: carried,
                                               verifiedStreamID: nil) == .syncing,
              "Syncing outranks everything else")

        // Opposing teams ---------------------------------------------------
        var conflict = store
        conflict.set(pref(fox, "FOX", "Buffalo Bills"), for: game.awayKey)
        let resolved = conflict.resolve(game, matchingReady: true, availableStreamIDs: carried,
                                        verifiedStreamID: verified)
        check(resolved == .chooseFeed(home: TeamFeedOption(team: "Kansas City Chiefs", streamID: espn, channelName: "ESPN"),
                                      away: TeamFeedOption(team: "Buffalo Bills", streamID: fox, channelName: "FOX")),
              "Two different preferences ask which feed to use")

        var agree = store
        agree.set(pref(espn, "ESPN", "Buffalo Bills"), for: game.awayKey)
        check(agree.resolve(game, matchingReady: true, availableStreamIDs: carried,
                            verifiedStreamID: verified) == .play(streamID: espn, source: .homePreference),
              "Two preferences naming the same channel do not ask")

        // Away-only preference.
        var awayOnly = TeamChannelPreferences()
        awayOnly.set(pref(fox, "FOX", "Buffalo Bills"), for: game.awayKey)
        check(awayOnly.resolve(game, matchingReady: true, availableStreamIDs: carried,
                               verifiedStreamID: verified) == .play(streamID: fox, source: .awayPreference),
              "The away team's preference applies when the home team has none")

        // Unavailable / removed channels -----------------------------------
        let withoutESPN: Set<Int> = [fox, regional, verified]
        check(store.resolve(game, matchingReady: true, availableStreamIDs: withoutESPN,
                            verifiedStreamID: verified) == .play(streamID: verified, source: .verified),
              "An unavailable preference falls back to Lineup's verified match")
        check(store.preference(for: game.homeKey)?.streamID == espn,
              "Falling back must not delete the preference")
        check(store.resolve(game, matchingReady: true, availableStreamIDs: withoutESPN,
                            verifiedStreamID: nil) == .pick,
              "With no preference available and no verified match, the viewer picks")
        check(store.resolve(game, matchingReady: true, availableStreamIDs: [],
                            verifiedStreamID: nil) == .pick,
              "A provider carrying nothing yet still ends at the picker, not a crash")
        // A match can outlive the channel list it was built from, so the
        // fallback is only a fallback while the provider still carries it.
        check(store.resolve(game, matchingReady: true, availableStreamIDs: [fox],
                            verifiedStreamID: verified) == .pick,
              "A verified match the provider no longer carries is not played")

        // Conflict where only one side's channel survives: no question to ask.
        check(conflict.resolve(game, matchingReady: true, availableStreamIDs: withoutESPN,
                               verifiedStreamID: verified) == .play(streamID: fox, source: .awayPreference),
              "A conflict resolves itself when one channel is gone")

        // Provider scoping -------------------------------------------------
        // A store belongs to one provider; another provider starts empty and a
        // channel identifier never leaks across.
        let otherProvider = TeamChannelPreferences()
        check(otherProvider.preference(for: game.homeKey) == nil, "A different provider starts with no preferences")
        check(otherProvider.resolve(game, matchingReady: true, availableStreamIDs: carried,
                                    verifiedStreamID: verified) == .pick,
              "Switching providers does not inherit the previous provider's channel")

        // Listing and removal ----------------------------------------------
        var listing = TeamChannelPreferences()
        listing.set(pref(espn, "ESPN", "Kansas City Chiefs", at: 100), for: game.homeKey)
        listing.set(pref(fox, "FOX", "Buffalo Bills", at: 200), for: game.awayKey)
        let rows = listing.listed()
        check(rows.count == 2, "Every saved preference is listed")
        check(rows[0].preference.teamName == "Buffalo Bills", "Newest first")
        check(rows[0].key.storageKey == "NFL|BUF", "A listed row round-trips its key")
        check(rows[0].id == "NFL|BUF", "A listed row is identified by its team key")
        listing.remove(for: game.awayKey)
        check(listing.count == 1 && listing.preference(for: game.awayKey) == nil, "A preference can be removed")
        check(listing.preference(for: game.homeKey) != nil, "Removing one team leaves the other")
        listing.removeAll()
        check(listing.isEmpty, "All preferences can be cleared at once")

        print("Team channel preference checks passed")
    }
}
