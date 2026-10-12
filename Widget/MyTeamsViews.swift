import SwiftUI
import UIKit
import WidgetKit

/// The app's restraint, carried onto the Home Screen: a flat charcoal ground,
/// white for what matters, grey for the rest, and red for the one thing that
/// is live. The teams' badges bring whatever other colour there is.
enum WidgetStyle {
    static let background = Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.42)
    /// The app's broadcast red, the same in every theme.
    static let live = Color(red: 1.0, green: 0x33 / 255.0, blue: 0x47 / 255.0)
    /// The pale rim behind a badge, so a navy shield still reads on charcoal.
    static let logoPlate = Color(red: 0xED / 255.0, green: 0xF1 / 255.0, blue: 0xF6 / 255.0)
}

struct MyTeamsView: View {
    let entry: MyTeamsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) {
                // The Lock Screen draws its own ground, and a charcoal panel
                // over a wallpaper would be the one dark block on it.
                if isAccessory { Color.clear } else { WidgetStyle.background }
            }
    }

    private var isAccessory: Bool {
        family == .accessoryRectangular || family == .accessoryInline || family == .accessoryCircular
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium: MyTeamsMediumView(entry: entry)
        case .accessoryRectangular: MyTeamsRectangularView(entry: entry)
        case .accessoryInline: MyTeamsInlineView(entry: entry)
        default: MyTeamsSmallView(entry: entry)
        }
    }
}

// MARK: - Home Screen

/// The next game, or the one on now: its league, both sides, and either the
/// score or when it starts.
private struct MyTeamsSmallView: View {
    let entry: MyTeamsEntry

    var body: some View {
        if let game = entry.games.first {
            SmallGame(game: game, entry: entry)
                .widgetURL(game.link.url)
        } else {
            EmptyShelf(followsTeams: entry.followsTeams)
        }
    }
}

private struct SmallGame: View {
    let game: HomeShelfGame
    let entry: MyTeamsEntry

    private var isLive: Bool { game.showsAsLive(at: entry.date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(game.league)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WidgetStyle.secondary)
                Spacer(minLength: 4)
                if isLive { LiveLabel() }
            }
            Spacer(minLength: 6)
            if game.isEvent, let name = game.eventName {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WidgetStyle.primary)
                    .lineLimit(3)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TeamLine(abbreviation: game.awayAbbreviation, rank: game.awayRank,
                             score: isLive ? game.awayScore : nil, logo: entry.logo(game.awayLogo))
                    TeamLine(abbreviation: game.homeAbbreviation, rank: game.homeRank,
                             score: isLive ? game.homeScore : nil, logo: entry.logo(game.homeLogo))
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 1) {
                if isLive {
                    if !game.status.isEmpty {
                        Text(game.status)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WidgetStyle.primary)
                            .lineLimit(1)
                    }
                } else {
                    Text(game.startLabel(relativeTo: entry.date))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let channel = game.channelName {
                    Text(channel)
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetStyle.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One side of a game on the small widget: badge, abbreviation, and the score
/// once there is one.
private struct TeamLine: View {
    let abbreviation: String
    let rank: Int?
    let score: String?
    let logo: UIImage?

    var body: some View {
        HStack(spacing: 8) {
            TeamMark(image: logo, fallback: abbreviation, size: 24)
            RankedAbbreviation(abbreviation: abbreviation, rank: rank, size: 15)
            Spacer(minLength: 4)
            if let score {
                Text(score)
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(WidgetStyle.primary)
            }
        }
    }
}

/// Up to three games, one to a row, each opening its own game.
private struct MyTeamsMediumView: View {
    let entry: MyTeamsEntry

    var body: some View {
        if entry.games.isEmpty {
            EmptyShelf(followsTeams: entry.followsTeams)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(entry.games.prefix(3))) { game in
                    Link(destination: game.link.url) {
                        GameRow(game: game, entry: entry)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct GameRow: View {
    let game: HomeShelfGame
    let entry: MyTeamsEntry

    private var isLive: Bool { game.showsAsLive(at: entry.date) }

    var body: some View {
        HStack(spacing: 10) {
            matchup
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                if isLive {
                    LiveLabel()
                    Text(game.status.isEmpty ? (game.channelName ?? game.league) : game.status)
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetStyle.secondary)
                        .lineLimit(1)
                } else {
                    Text(game.startLabel(relativeTo: entry.date))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(game.channelName ?? game.league)
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetStyle.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var matchup: some View {
        if game.isEvent, let name = game.eventName {
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WidgetStyle.primary)
                .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                RowSide(abbreviation: game.awayAbbreviation, rank: game.awayRank,
                        score: isLive ? game.awayScore : nil, logo: entry.logo(game.awayLogo))
                Text(isLive && game.awayScore != nil ? "\u{2013}" : "@")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetStyle.tertiary)
                RowSide(abbreviation: game.homeAbbreviation, rank: game.homeRank,
                        score: isLive ? game.homeScore : nil, logo: entry.logo(game.homeLogo))
            }
        }
    }
}

private struct RowSide: View {
    let abbreviation: String
    let rank: Int?
    let score: String?
    let logo: UIImage?

    var body: some View {
        HStack(spacing: 5) {
            TeamMark(image: logo, fallback: abbreviation, size: 20)
            RankedAbbreviation(abbreviation: abbreviation, rank: rank, size: 14)
            if let score {
                Text(score)
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(WidgetStyle.primary)
            }
        }
    }
}

// MARK: - Lock Screen

/// Lock Screen text takes the system's own vibrant colours, so these views
/// use the hierarchical styles rather than the Home Screen's greys.
private struct MyTeamsRectangularView: View {
    let entry: MyTeamsEntry

    var body: some View {
        if let game = entry.games.first {
            VStack(alignment: .leading, spacing: 1) {
                Text(heading(for: game))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(game.matchupLine(at: entry.date))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail(for: game))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(game.link.url)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("My Teams")
                    .font(.system(size: 15, weight: .semibold))
                Text(entry.followsTeams ? "No games in the next two days" : "Follow teams in Lineup")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heading(for game: HomeShelfGame) -> String {
        game.showsAsLive(at: entry.date) ? "LIVE \u{00B7} " + game.league : game.league
    }

    private func detail(for game: HomeShelfGame) -> String {
        if game.showsAsLive(at: entry.date) {
            return game.status.isEmpty ? (game.channelName ?? "Live now") : game.status
        }
        let when = game.startLabel(relativeTo: entry.date)
        return game.channelName.map { when + " \u{00B7} " + $0 } ?? when
    }
}

/// One line above the clock: "BOS @ NYY 7:05 PM", or the score once it is on.
private struct MyTeamsInlineView: View {
    let entry: MyTeamsEntry

    var body: some View {
        if let game = entry.games.first {
            Text(line(for: game))
                .widgetURL(game.link.url)
        } else {
            Text("Lineup: no games soon")
        }
    }

    private func line(for game: HomeShelfGame) -> String {
        let matchup = game.matchupLine(at: entry.date)
        guard game.showsAsLive(at: entry.date) else {
            return matchup + " " + game.startLabel(relativeTo: entry.date)
        }
        return game.status.isEmpty ? matchup + " \u{00B7} Live" : matchup + " \u{00B7} " + game.status
    }
}

// MARK: - Pieces

private struct EmptyShelf: View {
    let followsTeams: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("My Teams")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WidgetStyle.primary)
            Text(followsTeams
                 ? "No games for your teams in the next two days."
                 : "Follow teams in Lineup to see their games here.")
                .font(.system(size: 12))
                .foregroundStyle(WidgetStyle.secondary)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LiveLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(WidgetStyle.live)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WidgetStyle.live)
        }
    }
}

/// A college team's Top 25 place, small and grey, ahead of its abbreviation.
private struct RankedAbbreviation: View {
    let abbreviation: String
    let rank: Int?
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let rank {
                Text(String(rank))
                    .font(.system(size: size * 0.7, weight: .semibold))
                    .foregroundStyle(WidgetStyle.tertiary)
            }
            Text(abbreviation)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(WidgetStyle.primary)
                .lineLimit(1)
        }
    }
}

/// A team's badge with the same tight pale rim the app gives it (see
/// `TeamBadge`), so a dark badge does not vanish into the charcoal. Without a
/// badge, the abbreviation stands in.
private struct TeamMark: View {
    let image: UIImage?
    let fallback: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                let art = Image(uiImage: image).resizable().scaledToFit()
                art.background {
                    WidgetStyle.logoPlate
                        .mask { art.blur(radius: max(0.8, size * 0.035)) }
                        .opacity(0.75)
                }
            } else {
                Text(String(fallback.prefix(3)))
                    .font(.system(size: size * 0.32, weight: .heavy))
                    .foregroundStyle(WidgetStyle.secondary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
