import Foundation
#if os(tvOS)
import TVServices
#endif
#if os(iOS)
import WidgetKit
#endif

/// Writes the shelf the Top Shelf and the Home Screen widget read.
///
/// The extensions see only what this writes (see `Shared/HomeShelf.swift`),
/// so it is called whenever something they show may have changed: the
/// schedule, the teams followed, playback progress, the app coming forward or
/// going away. Those arrive in bursts -- a schedule refresh can republish
/// `gamesByLeague` several times in a second -- so a call only asks for a
/// write, and the write happens once things have been still for two seconds.
///
/// A write that would put the same shelf on disk again is skipped, and so is
/// the reload that follows it. Asking the system to reload a widget costs part
/// of a daily budget, and asking the television to redraw its Top Shelf for
/// nothing is no kinder.
@MainActor
final class HomeShelfPublisher {
    static let shared = HomeShelfPublisher()

    /// Two days: today's games, tonight's, and tomorrow's whatever the hour.
    private let upcomingWindow: TimeInterval = 48 * 60 * 60
    private let limit = 10
    private var pendingWrite: Task<Void, Never>?
    /// The last shelf written, encoded with a fixed `savedAt` so two shelves
    /// with the same games and titles compare equal whenever they were made.
    private var lastWritten: Data?

    private init() {}

    /// Asks for the shelf to be rebuilt and written.
    ///
    /// `immediately` skips the wait. It is for the app leaving the front:
    /// that is the moment the Top Shelf comes into view, and a write still
    /// waiting out its two seconds may not get them once the app is suspended.
    func publish(library: SportsLibrary, media: MediaLibrary, immediately: Bool = false) {
        pendingWrite?.cancel()
        pendingWrite = nil
        if immediately {
            write(snapshot(library: library, media: media))
            return
        }
        pendingWrite = Task { [weak self, weak library, weak media] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, let library, let media else { return }
            self.write(self.snapshot(library: library, media: media))
        }
    }

    private func write(_ snapshot: HomeShelfSnapshot) {
        var comparable = snapshot
        comparable.savedAt = Date(timeIntervalSinceReferenceDate: 0)
        guard let fingerprint = try? HomeShelfStore.encoded(comparable),
              fingerprint != lastWritten else { return }
        // Nowhere shared means a build the extensions cannot read from
        // anyway. Remembering the fingerprint regardless keeps it from
        // rebuilding and re-encoding on every call.
        lastWritten = fingerprint
        guard HomeShelfStore.isShared else { return }
        HomeShelfStore.write(snapshot)
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Building the shelf

    private func snapshot(library: SportsLibrary, media: MediaLibrary) -> HomeShelfSnapshot {
        let now = Date()
        let follows = !library.followedTeams.isEmpty
        return HomeShelfSnapshot(
            savedAt: now,
            games: follows ? games(in: library, now: now) : [],
            continueWatching: continueWatching(in: media),
            followsTeams: follows
        )
    }

    private func games(in library: SportsLibrary, now: Date) -> [HomeShelfGame] {
        // Until a schedule has been read -- the first seconds after launch, a
        // change of provider, a launch with no network -- an empty list means
        // "not known yet" rather than "no games". Writing it would blank the
        // Top Shelf and the widget each time, so the games already on the
        // shelf stay, less any that have since finished.
        guard !library.scheduleLoadedLeagues.isEmpty else {
            let previous = HomeShelfStore.read()?.games ?? []
            return Array(HomeShelfGame.current(previous, at: now).prefix(limit))
        }
        let horizon = now.addingTimeInterval(upcomingWindow)
        let followed = library.games(for: nil).filter { game in
            library.isFollowing(game) && (game.isLive || game.start <= horizon)
        }
        let ordered = followed.sorted { left, right in
            if left.isLive != right.isLive { return left.isLive }
            if left.start != right.start { return left.start < right.start }
            return left.id < right.id
        }
        return ordered.prefix(limit).map { shelfGame($0, channel: library.stream(for: $0)?.name) }
    }

    private func shelfGame(_ game: SportsGame, channel: String?) -> HomeShelfGame {
        // Only a game the feed itself calls under way has a clock line worth
        // repeating. One that is live by the clock alone -- the feed is late
        // saying so -- still carries its pre-game detail, which is a date.
        let isUnderWay = game.state == "in"
        let hasScore = game.isLive && !game.awayScore.isEmpty && !game.homeScore.isEmpty
        return HomeShelfGame(
            id: game.id,
            league: game.league.shortName,
            awayName: game.awayTeam,
            homeName: game.homeTeam,
            awayAbbreviation: game.awayAbbreviation,
            homeAbbreviation: game.homeAbbreviation,
            awayLogo: Self.nonEmpty(game.awayLogo),
            homeLogo: Self.nonEmpty(game.homeLogo),
            awayScore: hasScore ? game.awayScore : nil,
            homeScore: hasScore ? game.homeScore : nil,
            awayRank: game.awayRank,
            homeRank: game.homeRank,
            start: game.start,
            isLive: game.isLive,
            status: isUnderWay ? game.status : "",
            channelName: Self.nonEmpty(channel),
            isEvent: game.isEvent,
            eventName: Self.nonEmpty(game.eventName)
        )
    }

    private func continueWatching(in media: MediaLibrary) -> [HomeShelfMedia] {
        media.continueWatching.prefix(limit).map { record in
            let item = record.item
            let isEpisode = item.type == "Episode"
            // Episodes rarely have backdrops of their own, but their primary
            // art is already a 16:9 still, which is the shape wanted here.
            let landscape = media.backdropURL(for: item, width: 800) ?? media.imageURL(for: item, width: 800)
            let poster = isEpisode
                ? (media.seriesPosterURL(for: item, width: 400) ?? media.imageURL(for: item, width: 400))
                : media.imageURL(for: item, width: 400)
            return HomeShelfMedia(
                id: record.id,
                profileID: record.profileID,
                itemID: item.id,
                title: isEpisode ? (Self.nonEmpty(item.seriesName) ?? item.name) : item.name,
                subtitle: isEpisode ? Self.episodeLine(item) : item.productionYear.map(String.init),
                imageURL: landscape?.absoluteString,
                posterURL: poster?.absoluteString,
                // In two-percent steps. Playback reports its position every
                // few seconds, and a bar on a tile cannot show the difference
                // between them -- only rewrite the shelf when it could.
                progress: (record.fraction * 50).rounded() / 50
            )
        }
    }

    /// "S2 · E5 · Episode name", with whichever parts the server knows.
    private static func episodeLine(_ item: MediaItem) -> String? {
        var parts: [String] = []
        if let episode = item.indexNumber {
            parts.append("S\(item.parentIndexNumber ?? 1)")
            parts.append("E\(episode)")
        }
        if let name = nonEmpty(item.name), name != item.seriesName { parts.append(name) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
