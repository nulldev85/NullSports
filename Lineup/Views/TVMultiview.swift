import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

/// How a multiview session arranges its two pictures. The last one chosen is
/// remembered for the next session.
enum MultiviewLayout: String {
    /// Two pictures the same size, side by side.
    case sideBySide
    /// One large picture with a smaller one beside it.
    case bigAndSmall

    var title: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .bigAndSmall: "Big + Small"
        }
    }

    var symbol: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .bigAndSmall: "pip"
        }
    }

    var other: MultiviewLayout { self == .sideBySide ? .bigAndSmall : .sideBySide }
}

/// The session's two players, made once and kept for as long as it runs.
///
/// Nothing here is published, deliberately: each picture watches its own
/// player, so a stream reporting its progress redraws that picture and not
/// the arrangement around it.
@MainActor
final class MultiviewPlayers: ObservableObject {
    let tiles = [TVPlaybackController(primaryOutput: true), TVPlaybackController(primaryOutput: false)]
}

/// A game whose stream failed everywhere, waiting for a channel to be chosen.
struct MultiviewChannelChoice: Identifiable {
    let tile: Int
    let game: SportsGame
    var id: String { "\(tile)|\(game.id)" }
}

/// Two games at once.
///
/// Both players are made when the session starts and kept until it ends.
/// Every change of arrangement -- side by side, big and small, a swap, full
/// screen and back -- moves and scales the two pictures and never touches the
/// players, so neither stream stops, buffers or loses its place.
///
/// Sound follows the picture with focus. It is handed over, never shared: the
/// old picture's sound goes out before the new one's comes in, so the two are
/// never heard together. When focus leaves both for a moment -- a menu, a
/// sheet -- the sound stays where it was rather than going quiet.
struct MultiviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SportsLibrary.self) private var library
    /// Sports or the TV Guide, whichever it was opened from.
    @Environment(\.tvPlaybackPlace) private var place
    @StateObject private var players = MultiviewPlayers()
    @AppStorage("Lineup.multiviewLayout") private var storedLayout = MultiviewLayout.sideBySide.rawValue
    @FocusState private var focusedTile: Int?
    /// The picture whose sound is playing.
    @State private var audibleTile = 0
    /// Brings the new picture's sound in once the old one's is out.
    @State private var soundTask: Task<Void, Never>?
    /// In Big + Small, which picture is the big one.
    @State private var bigTile = 0
    /// A picture filling the screen, with the other still playing, unseen.
    @State private var fullScreenTile: Int?
    /// Names and the guide to the remote, shown for a few seconds after
    /// anything changes and then cleared off the pictures.
    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var choosingChannel: MultiviewChannelChoice?
    @State private var pickedChannel: TVPickedChannel?
    @State private var scopingChannel: TVPickedChannel?
    @State private var chosenTitles: [Int: String] = [:]
    let primary: XtreamStream
    let secondary: XtreamStream
    let primaryURLs: [URL]
    let secondaryURLs: [URL]
    let primaryGame: SportsGame?
    let secondaryGame: SportsGame?

    private var layout: MultiviewLayout { MultiviewLayout(rawValue: storedLayout) ?? .sideBySide }
    private var arrangement: Animation { .spring(response: 0.5, dampingFraction: 0.88) }

    var body: some View {
        GeometryReader { proxy in
            let screen = proxy.size
            ZStack {
                (fullScreenTile == nil ? LineupStyle.background : Color.black)
                ForEach(0..<2, id: \.self) { index in
                    tile(index, screen: screen)
                }
                if fullScreenTile == nil {
                    controls
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 52)
                        .transition(.opacity)
                } else {
                    fullScreenHint
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 56)
                        .opacity(chromeVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: screen.width, height: screen.height)
        }
        .ignoresSafeArea()
        .onAppear(perform: begin)
        .onDisappear {
            chromeTask?.cancel()
            soundTask?.cancel()
            players.tiles.forEach { $0.stop() }
        }
        .onChange(of: focusedTile) { _, tile in
            showChrome()
            // Focus in the bar below leaves the sound where it was.
            guard let tile, tile != audibleTile else { return }
            listen(to: tile)
        }
        .onPlayPauseCommand { switchLayout() }
        .onExitCommand(perform: back)
        .lineupFullScreenCover(item: $choosingChannel, onDismiss: {
            scopingChannel = library.asksScope(for: pickedChannel)
            pickedChannel = nil
        }) { choice in
            ManualGameChannelPicker(game: choice.game) { chosen in
                library.saveGameSelection(chosen, for: choice.game)
                pickedChannel = TVPickedChannel(game: choice.game, stream: chosen, startsMultiview: false)
                choosingChannel = nil
                chosenTitles[choice.tile] = chosen.name
                players.tiles[choice.tile].start(urls: library.playbackURLs(for: chosen),
                                                 muted: audibleTile != choice.tile, channelID: chosen.id)
            }
        }
        .channelScopePrompt($scopingChannel)
    }

    private func tile(_ index: Int, screen: CGSize) -> some View {
        let frame = tileFrame(index, screen: screen)
        let shown = fullScreenTile == nil || fullScreenTile == index
        let controller = players.tiles[index]
        let game = currentGame(index)
        return MultiviewTile(controller: controller,
                             game: game,
                             fallbackTitle: chosenTitles[index] ?? stream(index).name,
                             sharedTitle: chosenTitles[index] == nil
                                ? game.flatMap { library.sharedCoverageTitle(for: $0, on: stream(index)) } : nil,
                             size: frame.size,
                             audible: audibleTile == index,
                             fullScreen: fullScreenTile == index,
                             showsLabel: chromeVisible)
            .contentShape(Rectangle())
            // Only a picture on screen can hold focus: the one behind a full
            // screen picture keeps playing, but is out of the way.
            .focusable(shown)
            .focused($focusedTile, equals: index)
            .focusEffectDisabled()
            .tvSelectAction { select(index) }
            .onMoveCommand(perform: flip(from: index))
            .tvHoldMenu(currentGame(index)?.matchupLine ?? stream(index).name, symbol: "rectangle.split.2x1") {
                menuItems(for: index)
            }
            .position(x: frame.midX, y: frame.midY)
            .opacity(shown ? 1 : 0)
            .zIndex(zIndex(index))
    }

    /// Left and right flip between the two games while one fills the screen.
    /// Otherwise there is no handler, and focus moves between the pictures on
    /// its own.
    private func flip(from index: Int) -> ((MoveCommandDirection) -> Void)? {
        guard fullScreenTile == index else { return nil }
        return { direction in
            if direction == .left || direction == .right { showFullScreen(1 - index) }
        }
    }

    /// Held on a picture: the arrangement, the stream, and the way out.
    private func menuItems(for index: Int) -> [TVChoice] {
        var items: [TVChoice] = []
        if fullScreenTile == nil {
            items.append(TVChoice(layout.other.title, symbol: layout.other.symbol) { switchLayout() })
            if layout == .bigAndSmall {
                items.append(TVChoice("Swap Screens", symbol: "arrow.left.arrow.right") { swapPictures() })
            }
            items.append(TVChoice("Full Screen", symbol: "arrow.up.left.and.arrow.down.right") { showFullScreen(index) })
        } else {
            items.append(TVChoice("Back to Multiview", symbol: "arrow.down.right.and.arrow.up.left") { leaveFullScreen() })
        }
        items.append(TVChoice("Retry Stream", symbol: "arrow.clockwise") { players.tiles[index].retry() })
        if let game = currentGame(index), players.tiles[index].failover != nil {
            items.append(TVChoice("Choose Another Channel", symbol: "list.bullet.rectangle") {
                choosingChannel = MultiviewChannelChoice(tile: index, game: game)
            })
        }
        items.append(TVChoice("Exit Multiview", symbol: "xmark", isDestructive: true) { dismiss() })
        return items
    }

    // MARK: Arrangement

    /// Where a picture sits. A picture hidden behind a full screen one keeps
    /// its own place, so coming back is the same move in reverse.
    private func tileFrame(_ index: Int, screen: CGSize) -> CGRect {
        if fullScreenTile == index { return CGRect(origin: .zero, size: screen) }
        // Inside tvOS's safe area, which a television's overscan can trim
        // past, and centred in the space above the control bar.
        let margin: CGFloat = 90
        let gap: CGFloat = 24
        let middle = 60 + (screen.height - 60 - 170) / 2
        switch layout {
        case .sideBySide:
            let width = (screen.width - margin * 2 - gap) / 2
            let height = width * 9 / 16
            return CGRect(x: margin + CGFloat(index) * (width + gap), y: middle - height / 2,
                          width: width, height: height)
        case .bigAndSmall:
            let available = screen.width - margin * 2 - gap
            let bigWidth = (available * 0.72).rounded()
            let bigHeight = bigWidth * 9 / 16
            let top = middle - bigHeight / 2
            if index == bigTile {
                return CGRect(x: margin, y: top, width: bigWidth, height: bigHeight)
            }
            // Level with the middle of the big picture.
            let smallWidth = available - bigWidth
            let smallHeight = smallWidth * 9 / 16
            return CGRect(x: margin + bigWidth + gap, y: top + (bigHeight - smallHeight) / 2,
                          width: smallWidth, height: smallHeight)
        }
    }

    /// The full screen picture over everything. In Big + Small the big one
    /// passes over the small one, so a swap reads as the small picture
    /// coming forward.
    private func zIndex(_ index: Int) -> Double {
        if fullScreenTile == index { return 2 }
        if layout == .bigAndSmall { return index == bigTile ? 1 : 0 }
        return index == audibleTile ? 1 : 0
    }

    // MARK: Actions

    private func begin() {
        PlaybackJournal.shared.note("Split screen: " + primary.name + " and " + secondary.name)
        // Both are being watched: each holds the screen saver off while it
        // plays, and notes what it does under its channel's name.
        players.tiles[0].watched = .splitScreen(primary.name)
        players.tiles[1].watched = .splitScreen(secondary.name)
        for index in 0..<2 {
            let controller = players.tiles[index]
            if let game = index == 0 ? primaryGame : secondaryGame {
                configureGameFailover(controller, game: game, library: library) {
                    choosingChannel = MultiviewChannelChoice(tile: index, game: game)
                }
            }
        }
        // The second picture starts silent and at zero, so its sound has
        // somewhere to fade up from.
        players.tiles[1].fadeAudio(audible: false, over: 0)
        for tile in players.tiles { tile.place = place }
        players.tiles[0].start(urls: primaryURLs, muted: false, channelID: primary.id)
        players.tiles[1].start(urls: secondaryURLs, muted: true, channelID: secondary.id)
        audibleTile = 0
        bigTile = 0
        Task { @MainActor in
            await Task.yield()
            focusedTile = 0
        }
        showChrome()
    }

    /// Selecting a picture: a stream that failed is tried again; in Big +
    /// Small the small picture comes forward; otherwise the picture fills the
    /// screen.
    private func select(_ index: Int) {
        let controller = players.tiles[index]
        if controller.error != nil {
            controller.retry()
            return
        }
        if fullScreenTile != nil { return }
        if layout == .bigAndSmall && index != bigTile {
            swapPictures()
        } else {
            showFullScreen(index)
        }
    }

    private func swapPictures() {
        withAnimation(arrangement) { bigTile = 1 - bigTile }
        showChrome()
    }

    private func choose(_ option: MultiviewLayout) {
        guard option != layout else { return }
        switchLayout()
    }

    private func switchLayout() {
        guard fullScreenTile == nil else { return }
        withAnimation(arrangement) {
            // The game being listened to is the one that becomes big.
            if layout == .sideBySide { bigTile = audibleTile }
            storedLayout = layout.other.rawValue
        }
        showChrome()
    }

    private func showFullScreen(_ index: Int) {
        withAnimation(arrangement) { fullScreenTile = index }
        if focusedTile != index {
            // Focus can only land once the picture is on screen to take it.
            Task { @MainActor in
                await Task.yield()
                focusedTile = index
            }
        }
        showChrome()
    }

    private func leaveFullScreen() {
        withAnimation(arrangement) { fullScreenTile = nil }
        showChrome()
    }

    private func back() {
        if fullScreenTile != nil {
            leaveFullScreen()
        } else {
            PlaybackJournal.shared.note("Split screen closed: Back pressed")
            dismiss()
        }
    }

    /// Hand the sound to a picture: the other's goes out first, and only then
    /// does this one's come in. A crossfade had both playing at once while it
    /// ran, and a stream that reconnected partway through could be left
    /// playing under the other for good.
    private func listen(to index: Int) {
        audibleTile = index
        soundTask?.cancel()
        let heard = players.tiles[index]
        let quiet = players.tiles[1 - index]
        quiet.fadeAudio(audible: false, over: Self.soundOut)
        // Held silent until the other is out -- it may still be on its way
        // out itself, after a quick move there and back.
        heard.fadeAudio(audible: false, over: 0)
        soundTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(Self.soundOut + 0.02)) } catch { return }
            heard.fadeAudio(audible: true, over: 0.25)
        }
    }

    private static let soundOut = 0.18

    private func showChrome() {
        withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true }
        chromeTask?.cancel()
        chromeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            withAnimation(.easeInOut(duration: 0.5)) { chromeVisible = false }
        }
    }

    // MARK: Labels

    private func stream(_ index: Int) -> XtreamStream { index == 0 ? primary : secondary }

    /// The game as the schedule has it now, so its score stays current while
    /// the session runs.
    private func currentGame(_ index: Int) -> SportsGame? {
        guard let game = index == 0 ? primaryGame : secondaryGame else { return nil }
        return library.games(for: nil).first { $0.id == game.id } ?? game
    }

    /// The bar under the pictures: the two layouts, the arrangement and the
    /// way out. Down from either picture reaches it, and up goes back.
    private var controls: some View {
        VStack(spacing: 14) {
            Label("Move between the games to switch the sound", systemImage: "speaker.wave.2.fill")
                .font(.inter(15, .medium))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                .opacity(chromeVisible ? 1 : 0)
            LineupGlassGroup {
            HStack(spacing: 14) {
                ForEach([MultiviewLayout.sideBySide, .bigAndSmall], id: \.self) { option in
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                                 action: { choose(option) }) {
                        MultiviewControlLabel(title: option.title, symbol: option.symbol,
                                              selected: layout == option)
                    }
                }
                Rectangle().fill(LineupStyle.line).frame(width: 1, height: 34).padding(.horizontal, 6)
                if layout == .bigAndSmall {
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                                 action: { swapPictures() }) {
                        MultiviewControlLabel(title: "Swap", symbol: "arrow.left.arrow.right")
                    }
                }
                // The game being listened to, which is the outlined one.
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                             action: { showFullScreen(audibleTile) }) {
                    MultiviewControlLabel(title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right")
                }
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                             action: { dismiss() }) {
                    MultiviewControlLabel(title: "Exit", symbol: "xmark")
                }
            }
            .lineupFocusRegion()
            }
        }
    }

    /// Words only, not controls: a game filling the screen has nothing on
    /// top of it to select.
    private var fullScreenHint: some View {
        HStack(spacing: 26) {
            Label("Other game", systemImage: "arrow.left.and.right")
            Label("Back to multiview", systemImage: "arrow.uturn.backward")
        }
        .font(.inter(16, .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.85), radius: 8, y: 2)
    }
}

/// One picture in a multiview session.
///
/// The video is drawn at the size of the whole screen and scaled to the size
/// it is shown at, so moving between a small place, a large one and the
/// full screen never resizes what VLC draws into -- the move is a transform,
/// and the picture plays straight through it.
struct MultiviewTile: View {
    @ObservedObject var controller: TVPlaybackController
    let game: SportsGame?
    let fallbackTitle: String
    /// A tournament on the channel it shares, by what the channel is
    /// showing (`SportsLibrary.sharedCoverageTitle`).
    let sharedTitle: String?
    let size: CGSize
    let audible: Bool
    let fullScreen: Bool
    let showsLabel: Bool

    var body: some View {
        let radius: CGFloat = fullScreen ? 0 : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        TVHostedSurface(controller: controller, fullScreen: true)
            .frame(width: size.width, height: size.height)
            .overlay { MultiviewStatus(controller: controller) }
            .overlay(alignment: .bottomLeading) { label }
            .clipShape(shape)
            // The picture with the sound wears the edge; it is also the one
            // with focus whenever focus is on a picture at all.
            .overlay {
                shape.strokeBorder(Color.white.opacity(audible && !fullScreen ? 0.92 : (fullScreen ? 0 : 0.1)),
                                   lineWidth: audible && !fullScreen ? 3 : 1)
            }
            .shadow(color: .black.opacity(audible && !fullScreen ? 0.55 : 0), radius: 26, y: 12)
            .animation(.easeOut(duration: 0.2), value: audible)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + ", " + controller.engineTitle + (audible ? ", playing sound" : ""))
    }

    private var title: String {
        guard let game else { return controller.activeChannelName ?? fallbackTitle }
        // Until failover moves it to another channel.
        if controller.activeChannelName == nil, let sharedTitle { return sharedTitle }
        return liveHeadline(game)
    }

    /// The channel, under a game's score.
    private var detail: String? {
        guard game != nil else { return nil }
        return controller.activeChannelName ?? fallbackTitle
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .frame(width: 24)
                .opacity(audible ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.inter(19, .semibold)).lineLimit(1)
                if let detail {
                    Text(detail).font(.inter(14, .medium)).opacity(0.7).lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                TVPlaybackEngineBadge(engine: controller.engineKind)
                PlaybackBadgeFlow {
                    if controller.videoHeight > 0 { PlaybackFormatBadge(text: controller.qualityLabel) }
                    ForEach(controller.mediaInfo.badges, id: \.self) { PlaybackFormatBadge(text: $0) }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 14)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
        }
        .opacity(showsLabel ? 1 : 0)
    }
}

/// A picture's own trouble, said on the picture. Nothing in it takes focus:
/// selecting the picture retries a stream that failed, and holding it offers
/// the rest.
struct MultiviewStatus: View {
    @ObservedObject var controller: TVPlaybackController

    var body: some View {
        if controller.error != nil {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Stream unavailable").font(.inter(18, .semibold))
                Text("Select to retry  ·  Hold for more").font(.inter(14)).opacity(0.72)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.vertical, 20)
            .lineupLiquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous),
                               fallback: Color.black.opacity(0.7), border: .clear)
        } else if controller.reconnecting {
            VStack(spacing: 12) {
                ProgressView()
                Text("Reconnecting…").font(.inter(15, .semibold))
            }
            .foregroundStyle(.white)
            .padding(20)
            .lineupLiquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous),
                               fallback: Color.black.opacity(0.6), border: .clear)
        } else if let notice = controller.failoverNotice {
            Text(notice).font(.inter(15, .medium)).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .lineupLiquidGlass(Capsule(), fallback: Color.black.opacity(0.7), border: .clear)
        } else if !controller.isPlaying {
            ProgressView()
        }
    }
}

/// A control in the multiview bar, in the same dress as the player's own.
struct MultiviewControlLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    let symbol: String
    /// The layout in use, which carries a check.
    var selected = false

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .bold, design: .rounded)).frame(width: 22)
            Text(title).font(.inter(18, .semibold)).fixedSize()
            if selected {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, 22).frame(height: 52)
        .lineupLiquidGlass(shape, fallback: selected ? LineupStyle.raised : LineupStyle.surface.opacity(0.88),
                           border: selected ? LineupStyle.lightPurple.opacity(0.5) : LineupStyle.line,
                           prominent: selected)
        .lineupFocusLayer(focused, in: shape)
        .lineupShadow(.resting)
    }
}
