import SwiftUI
import UIKit

// What is left of the old Sports screen that the rest of the app shares:
// the hold menu on a game, the sport filter and its chip, the league and
// channel marks, and the live dot. The tab itself is `TVSportsBoard`.

/// The Live tab's reading of the theme.
///
/// Every colour here comes from LineupStyle's charcoal, light grey and white.
/// The one colour that is not the theme's is broadcast red, and it only ever
/// means on air; the teams bring their own.
enum LivePalette {
    static var text: Color { LineupStyle.text.opacity(0.78) }
    static var secondary: Color { LineupStyle.secondary.opacity(0.9) }
    static var card: Color { LineupStyle.surface }
    static var rule: Color { LineupStyle.line }
    static var accent: Color { LineupStyle.highlight }
    static var rim: Color { LineupStyle.liveSelectionBorder }
    static var onAir: Color { LineupStyle.liveDot }
}

/// Hold Select on any game: a reminder, either side into My Teams, or
/// multiview. The same on the board and in the rail, so following is offered
/// wherever a game is -- the rail is empty until somebody is followed, so a
/// follow that lived only there could never be reached on a fresh install.
struct LiveGameMenu: ViewModifier {
    @Environment(SportsLibrary.self) private var library
    @EnvironmentObject private var reminders: GameReminders
    @Environment(\.liveChooseChannel) private var chooseChannel
    @Environment(\.liveGameActions) private var actions
    @State private var showingRaceDetails = false
    let game: SportsGame
    let isPrimary: Bool
    let onStartMultiview: () -> Void

    func body(content: Content) -> some View {
        content.tvHoldMenu(game.matchupLine, symbol: "sportscourt", tint: LineupStyle.leagueColor(game.league)) {
            var items: [TVChoice] = []
            if game.league.isRacing {
                items.append(TVChoice("Race Details", symbol: "flag.checkered") { showingRaceDetails = true })
            }
            items += actions?.liveItems(for: game, library: library) ?? []
            if game.isUpcoming {
                let on = reminders.reminds(game)
                items.append(TVChoice(on ? "Remove Reminder" : "Remind Me", symbol: on ? "bell.slash" : "bell") {
                    reminders.toggleGame(game)
                })
            }
            // A channel of the viewer's own for this game, and whether to
            // keep it for either team, as on iPhone.
            if let chooseChannel {
                items.append(TVChoice("Choose Another Channel", symbol: "list.bullet.rectangle") { chooseChannel(game) })
            }
            items += actions?.teamItems(for: game, library: library) ?? []
            for team in library.followableSides(of: game) {
                let following = library.isFollowing(team.key)
                items.append(TVChoice(following ? "Remove \(team.name) from My Teams" : "Add \(team.name) to My Teams",
                                      symbol: following ? "star.slash" : "star", id: "follow-\(team.id)") {
                    library.toggleFollow(team)
                })
            }
            if library.stream(for: game) != nil {
                items.append(TVChoice("Start Multiview", symbol: "rectangle.split.2x1", isEnabled: !isPrimary,
                                      action: onStartMultiview))
            }
            return items
        }
        .lineupFullScreenCover(isPresented: $showingRaceDetails) { RacingSessionDetails(game: game) }
    }
}

/// The sport filter: one chip, at the head of the board it filters.
struct LiveLeagueFilter: View {
    @Binding var selectedLeague: SportsLeague?
    @State private var choosing = false

    private var title: String {
        selectedLeague.map(liveLeagueName) ?? "All sports"
    }

    var body: some View {
        // TVSelectable over a confirmation dialog, the shape the rest of the
        // app uses: a menu would draw the television's own focus plate over a
        // chip that already draws its own.
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { choosing = true }) {
            LiveChipLabel(symbol: "line.3.horizontal.decrease", title: title,
                          league: selectedLeague, trailing: "chevron.down")
        }
        .tvChoices("Show which sport?", symbol: "sportscourt", isPresented: $choosing) {
            [TVChoice("All Sports", id: "all", isSelected: selectedLeague == nil) { selectedLeague = nil }]
                + SportsLeague.allCases.map { league in
                    TVChoice(liveLeagueName(league), id: league.rawValue, isSelected: selectedLeague == league) {
                        selectedLeague = league
                    }
                }
        }
        .accessibilityLabel("Filter by sport")
    }
}

/// A chip's face. Focus fills it, the way the app's other action pills mark
/// focus, rather than drawing a second frame around it.
struct LiveChipLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let symbol: String
    let title: String
    var league: SportsLeague?
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            if let league {
                LeagueLogo(league: league, size: 24)
            } else {
                LineupIconTile(symbol: symbol, size: 30)
            }
            Text(title).font(.inter(17, .semibold)).lineLimit(1)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 13, weight: .bold, design: .rounded)).opacity(0.7)
            }
        }
        .foregroundStyle(LivePalette.text)
        .padding(.leading, league == nil ? 8 : 20).padding(.trailing, 20).frame(height: 46)
        // The phone's pill: the panels' fill, no outline.
        .background(LivePalette.card, in: Capsule())
        .lineupFocusLayer(focused, in: Capsule())
        .lineupShadow(.lifted, on: focused)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }
}

/// A league as the sport filter names it.
func liveLeagueName(_ league: SportsLeague) -> String {
    league == .ncaaf ? "College" : league.shortName
}

/// The matchup in a line: "BOS 3 – NYY 5", "BOS @ MIL", or an event's name.
func liveHeadline(_ game: SportsGame) -> String {
    if game.isEvent { return game.matchupLine }
    if game.isLive && !game.awayScore.isEmpty && !game.homeScore.isEmpty {
        return "\(game.awayAbbreviation) \(game.awayScore)  –  \(game.homeAbbreviation) \(game.homeScore)"
    }
    return "\(game.awayAbbreviation) \(game.sidesSymbol) \(game.homeAbbreviation)"
}

/// On air, as a small red dot.
///
/// Still. It breathed, from phase to phase, and a breathing dot is a frame
/// drawn on the main thread for every live programme on screen for as long
/// as the screen is up -- a dozen of them down the Guide at once, all the
/// time the viewer was moving through it. The red and the word beside it
/// already say *now*.
struct PulsingLiveDot: View {
    let size: CGFloat

    /// Three quarters of what each caller asked for: every live dot in the
    /// app gets smaller at once, without reworking the rows that hold them.
    private var diameter: CGFloat { (size * 0.72).rounded() }

    var body: some View {
        dot(opacity: 1).accessibilityHidden(true)
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(LineupStyle.liveDot)
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
    }
}

func nonempty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
}

func sportsSymbol(_ league: SportsLeague) -> String {
    switch league {
    case .nfl, .ncaaf: "football.fill"
    case .nba: "basketball.fill"
    case .nhl: "hockey.puck.fill"
    case .mlb: "baseball.fill"
    case .ufc: "figure.martial.arts"
    case .atp, .wta: "tennisball.fill"
    case .soccer: "soccerball"
    case .f1, .nascar: "flag.checkered"
    }
}

struct LeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat
    /// Room across for a mark wider than it is tall -- UFC's, the tennis
    /// tours' -- which a square would shrink. Square by default.
    var width: CGFloat?

    private var logoURL: URL? {
        guard league != .ncaaf && league != .ufc && !league.isTennis else { return nil }
        return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/\(league.rawValue).png")
    }

    var body: some View {
        Group {
            // ESPN has no league mark for these: UFC, the NCAA's and the
            // tennis tours' come with the app.
            if league == .soccer || league.isRacing {
                SportsMark(league: league, size: size)
            } else if league == .ufc || league == .ncaaf || league.isTennis {
                Image("League-\(league.rawValue)").resizable().scaledToFit()
            } else {
                LineupArtView(url: logoURL, width: size) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple)
                    } else {
                        Image(systemName: sportsSymbol(league))
                            .resizable().scaledToFit()
                            .padding(size * 0.18)
                            .foregroundStyle(LineupStyle.secondary)
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
        .frame(width: width ?? size, height: size)
        .clipped()
    }
}

struct ScreenHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(LineupStyle.highlight).frame(width: 42, height: 4)
            Text(title).font(.inter(44, .bold)).tracking(-1).foregroundStyle(LineupStyle.text)
            Text(detail).font(.inter(.callout, .medium)).foregroundStyle(LineupStyle.secondary)
        }
    }
}

struct ChannelLogo: View {
    let url: String?
    var width: CGFloat = 74
    var height: CGFloat = 54
    var body: some View {
        LineupArtView(url: URL(string: url ?? ""), width: width) { loaded in
            if let image = loaded { image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple) }
            else { Image(systemName: "tv").font(.inter(.caption)).foregroundStyle(LineupStyle.secondary) }
        }
        .transaction { $0.animation = nil }
        .padding(4).frame(width: width, height: height).background(LineupStyle.raised)
    }
}
