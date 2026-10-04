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

        // A preference is a preference among channels CARRYING this game.
        // Availability and verification are different questions: the regional
        // network exists all season and only carries some of the games.
        func resolve(_ store: TeamChannelPreferences, ready: Bool = true,
                     available: Set<Int> = carried, verified: Set<Int> = [],
                     match: Int? = nil) -> PreferredChannel {
            store.resolve(game, matchingReady: ready, availableStreamIDs: available,
                          verifiedStreamIDs: verified, verifiedStreamID: match)
        }

        // 1. Preferred channel exists and carries the game.
        check(resolve(store, verified: [espn], match: espn) == .play(streamID: espn, source: .homePreference),
              "A verified saved preference plays automatically")

        // 2. Preferred channel exists but is NOT carrying this game. The Cubs
        // preference is Marquee; tonight's game is national. Marquee is in the
        // lineup and must not be chosen.
        check(resolve(store, verified: [regional], match: regional) == .play(streamID: regional, source: .verified),
              "An available but unverified preference yields to the verified feed")
        check(store.preference(for: game.homeKey)?.streamID == espn,
              "Yielding does not delete the preference")

        // 3. Matching still running: nothing is verified yet, so nothing plays.
        check(resolve(store, ready: false, verified: []) == .syncing,
              "An unverified preference does not play from restored cache")
        check(resolve(store, ready: false, verified: [espn], match: espn) == .syncing,
              "Not even a verified-looking preference outranks an unsettled index")

        // 4. Preferred channel missing from the lineup entirely.
        check(resolve(store, available: withoutESPNEarly, verified: [regional],
                      match: regional) == .play(streamID: regional, source: .verified),
              "A missing preference falls back to the verified feed")
        check(store.preference(for: game.homeKey)?.streamID == espn, "…and is still saved")

        // 5. Nothing verified at all.
        check(resolve(store, verified: []) == .pick, "With no verified feed the viewer picks")
        check(resolve(TeamChannelPreferences(), verified: [], match: nil) == .pick,
              "No preference and no match also picks")
        check(resolve(store, verified: [espn], match: nil) == .play(streamID: espn, source: .homePreference),
              "A verified preference does not need Lineup to have its own match")
        // A match Lineup holds but the provider no longer carries is not played.
        check(resolve(store, available: [fox], verified: [], match: verified) == .pick,
              "A verified match the provider dropped is not played")

        // 6. Both teams have preferences, only one is carrying the game.
        var conflict = store
        conflict.set(pref(fox, "FOX", "Buffalo Bills"), for: game.awayKey)
        check(resolve(conflict, verified: [fox], match: fox) == .play(streamID: fox, source: .awayPreference),
              "One verified side plays without raising a conflict")
        check(resolve(conflict, verified: [espn], match: espn) == .play(streamID: espn, source: .homePreference),
              "…either side")

        // 7. Both verified and disagreeing.
        check(resolve(conflict, verified: [espn, fox], match: espn)
              == .chooseFeed(home: TeamFeedOption(team: "Kansas City Chiefs", streamID: espn, channelName: "ESPN"),
                             away: TeamFeedOption(team: "Buffalo Bills", streamID: fox, channelName: "FOX")),
              "Two verified, disagreeing preferences ask which feed")

        var agree = store
        agree.set(pref(espn, "ESPN", "Buffalo Bills"), for: game.awayKey)
        check(resolve(agree, verified: [espn], match: espn) == .play(streamID: espn, source: .homePreference),
              "Two preferences naming the same verified channel do not ask")

        // 9. The exclusive-national case, end to end: the regional preference is
        // carried by the provider but is not showing the game, and the national
        // feed is. The regional channel must never be the answer.
        var cubs = TeamChannelPreferences()
        let marquee = regional, appleFeed = fox
        cubs.set(pref(marquee, "Marquee Sports Network", "Chicago Cubs"), for: game.homeKey)
        let exclusive = resolve(cubs, available: [marquee, appleFeed], verified: [appleFeed], match: appleFeed)
        check(exclusive == .play(streamID: appleFeed, source: .verified),
              "An exclusive national game opens the verified national feed")
        if case let .play(id, _) = exclusive { check(id != marquee, "…and never the regional preference") }
        check(cubs.preference(for: game.homeKey)?.streamID == marquee,
              "The regional preference survives for the next game")

        // Provider scoping is unchanged by any of this.
        check(TeamChannelPreferences().resolve(game, matchingReady: true, availableStreamIDs: carried,
                                               verifiedStreamIDs: [espn], verifiedStreamID: espn)
              == .play(streamID: espn, source: .verified),
              "Another provider inherits no preference and uses the verified feed")

        // Exact-game choices ------------------------------------------------
        // "Just this game" used to dismiss its menu without writing anything.
        // Keep this store pure and date-driven so refresh/relaunch behavior and
        // expiry are deterministic under test.
        let pickedAt = Date(timeIntervalSince1970: 10_000)
        let startsAt = Date(timeIntervalSince1970: 9_000)
        let exact = GameChannelSelection(streamID: regional, channelName: "MLB 01",
                                         gameStart: startsAt, savedAt: pickedAt)
        var games = GameChannelSelections()
        games.set(exact, for: "mlb-2026-09-23-wsh-det")
        check(games.selection(for: "mlb-2026-09-23-wsh-det", at: pickedAt)?.streamID == regional,
              "A manual choice is remembered for the exact game")
        check(games.selection(for: "mlb-2026-09-24-wsh-det", at: pickedAt) == nil,
              "An exact-game choice never leaks into another game")
        let gameData = try! JSONEncoder().encode(games)
        let restoredGames = try! JSONDecoder().decode(GameChannelSelections.self, from: gameData)
        check(restoredGames == games, "An exact-game choice survives an encode/decode round trip")
        check(restoredGames.selection(for: "mlb-2026-09-23-wsh-det",
                                      at: exact.expiresAt.addingTimeInterval(1)) == nil,
              "A finished game's manual choice expires")
        var prunedGames = restoredGames
        prunedGames.prune(at: exact.expiresAt.addingTimeInterval(1))
        check(prunedGames == GameChannelSelections(), "Expired game choices are removed from storage")

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
