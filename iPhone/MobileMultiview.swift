import SwiftUI

/// Two channels at once, each with its game when it has one.
struct MobileMultiviewSession: Identifiable {
    struct Tile {
        let stream: XtreamStream
        let game: SportsGame?
    }
    let id = UUID()
    let tiles: [Tile]
}

/// Multiview's two players, made once for the session and never rebuilt by a
/// change of layout: moving a picture moves its frame, not its stream.
@MainActor
final class MobileMultiviewPlayers: ObservableObject {
    let tiles = [MobilePlaybackController(), MobilePlaybackController()]
}

/// How the two pictures share the screen.
enum MobileMultiviewLayout: String {
    /// Two equal pictures: side by side on its side, one over the other
    /// upright.
    case equal
    /// One large and one small beside it, on its side.
    case bigAndSmall
}

/// Multiview on the phone: two live channels on one screen, the sound
/// following the picture last tapped.
///
/// Tap a picture to hear it. Double-tap it to make it the large one. The
/// controls along the top -- close, layout, swap -- come and go with a tap.
struct MobileMultiviewView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let session: MobileMultiviewSession
    @StateObject private var players = MobileMultiviewPlayers()
    @AppStorage("Lineup.mobile.multiviewLayout") private var layoutName = MobileMultiviewLayout.equal.rawValue
    /// The channel each tile plays now; failover can move it on.
    @State private var streams: [XtreamStream]
    /// Which tile is heard.
    @State private var audible = 0
    /// Where each tile sits: the first place is the left, the top, or the
    /// large picture.
    @State private var order = [0, 1]
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// A tile choosing another channel for its game.
    @State private var choosingFor: Int?
    /// The quiet tile, stopped while the app is away and opened again on its
    /// return: no sense decoding a picture nobody can see or hear.
    @State private var restInBackground = false

    init(session: MobileMultiviewSession) {
        self.session = session
        _streams = State(initialValue: session.tiles.map(\.stream))
    }

    private var layout: MobileMultiviewLayout {
        MobileMultiviewLayout(rawValue: layoutName) ?? .equal
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The pictures use the whole screen, edge to edge.
            GeometryReader { proxy in
                let size = proxy.size
                let sideways = size.width > size.height
                ZStack(alignment: .topLeading) {
                    Color.black
                    ForEach(0..<2, id: \.self) { index in
                        let frame = tileFrame(index, in: size, sideways: sideways)
                        MobileMultiviewTile(controller: players.tiles[index],
                                            stream: streams[index], game: session.tiles[index].game,
                                            audible: audible == index,
                                            compact: frame.width < size.width * 0.4,
                                            onTap: { listen(to: index) },
                                            onDoubleTap: { promote(index) },
                                            onRetry: { start(index) },
                                            onChooseChannel: session.tiles[index].game == nil ? nil : { choosingFor = index })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .zIndex(order[0] == index ? 0 : 1)
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: order)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: layoutName)
            }
            .ignoresSafeArea()
            // The controls keep clear of the notch and the island.
            if chromeVisible {
                controls(sideways: verticalSizeClass == .compact)
                    .padding(.horizontal, 16).padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onChange(of: scenePhase) { _, phase in sceneChanged(active: phase == .active) }
        // The screen stays on while the pictures play; either player
        // stopping or reconnecting would otherwise let it sleep.
        .task {
            while !Task.isCancelled {
                UIApplication.shared.isIdleTimerDisabled = true
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(item: Binding(get: { choosingFor.map(ChoosingTile.init) }, set: { choosingFor = $0?.index })) { choice in
            if let game = session.tiles[choice.index].game {
                MobileChannelPicker(library: library, game: game) { stream in
                    library.saveGameSelection(stream, for: game)
                    streams[choice.index] = stream
                    choosingFor = nil
                    start(choice.index)
                }
            }
        }
    }

    private struct ChoosingTile: Identifiable {
        let index: Int
        var id: Int { index }
    }

    // MARK: Layout

    /// Where a tile sits. Every picture keeps the shape of a television
    /// picture and is centred in the room it is given.
    private func tileFrame(_ index: Int, in size: CGSize, sideways: Bool) -> CGRect {
        let place = order.firstIndex(of: index) ?? index
        let gap: CGFloat = 4
        func fitted(_ room: CGRect) -> CGRect {
            let width = min(room.width, room.height * 16 / 9)
            let height = width * 9 / 16
            return CGRect(x: room.midX - width / 2, y: room.midY - height / 2, width: width, height: height)
        }
        if !sideways {
            // One over the other, as near the middle as two pictures go.
            let height = size.width * 9 / 16
            let top = max(0, (size.height - height * 2 - gap) / 2)
            return CGRect(x: 0, y: top + CGFloat(place) * (height + gap), width: size.width, height: height)
        }
        switch layout {
        case .equal:
            let half = (size.width - gap) / 2
            return fitted(CGRect(x: CGFloat(place) * (half + gap), y: 0, width: half, height: size.height))
        case .bigAndSmall:
            let bigWidth = (size.width - gap) * 0.70
            if place == 0 { return fitted(CGRect(x: 0, y: 0, width: bigWidth, height: size.height)) }
            let smallWidth = size.width - bigWidth - gap
            let small = smallWidth * 9 / 16
            // The small picture level with the top of the large one.
            let big = fitted(CGRect(x: 0, y: 0, width: bigWidth, height: size.height))
            return CGRect(x: bigWidth + gap, y: big.minY, width: smallWidth, height: small)
        }
    }

    private func controls(sideways: Bool) -> some View {
        HStack(spacing: 10) {
            button("xmark", label: "Close multiview") { dismiss() }
            Spacer(minLength: 8)
            Text("Multiview").font(.inter(15, .bold)).foregroundStyle(LineupStyle.mediaText)
                .padding(.horizontal, 14).frame(height: 36)
                .lineupGlassControl(Capsule())
            Spacer(minLength: 8)
            if sideways {
                button(layout == .equal ? "rectangle.inset.topright.filled" : "rectangle.split.2x1",
                       label: layout == .equal ? "Large and small" : "Side by side") { switchLayout() }
            }
            button("arrow.left.arrow.right", label: "Swap pictures") { swap() }
        }
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showChrome()
        } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(LineupStyle.mediaText)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .lineupGlassControl(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    /// Sound from this picture only. The other is muted, not paused: both
    /// stay live.
    private func listen(to index: Int) {
        showChrome()
        guard audible != index else { return }
        audible = index
        for (tile, controller) in players.tiles.enumerated() { controller.audioMuted = tile != index }
    }

    /// The tapped picture becomes the large one, and the one heard.
    private func promote(_ index: Int) {
        listen(to: index)
        if layout != .bigAndSmall { layoutName = MobileMultiviewLayout.bigAndSmall.rawValue }
        if order[0] != index { order = [index, 1 - index] }
    }

    private func swap() { order = [order[1], order[0]] }

    private func switchLayout() {
        if layout == .equal {
            layoutName = MobileMultiviewLayout.bigAndSmall.rawValue
            // The one being heard is the one worth the room.
            if order[0] != audible { order = [audible, 1 - audible] }
        } else {
            layoutName = MobileMultiviewLayout.equal.rawValue
        }
    }

    private func showChrome() {
        chromeVisible = true
        hideTask?.cancel()
        hideTask = Task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            chromeVisible = false
        }
    }

    // MARK: Playback

    private func begin() {
        for (index, controller) in players.tiles.enumerated() {
            controller.isPrimaryOutput = index == 0
            controller.allowsPictureInPicture = false
            controller.audioMuted = index != audible
            if let game = session.tiles[index].game { controller.failover = failover(for: game, tile: index) }
        }
        // One after the other, a moment apart: the preview has only just
        // let its connection go, and a provider counts a closing stream
        // until it has closed.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            start(0)
            try? await Task.sleep(for: .milliseconds(900))
            start(1)
        }
        showChrome()
    }

    private func start(_ index: Int) {
        let stream = streams[index]
        players.tiles[index].start(urls: library.playbackURLs(for: stream), channelID: stream.id)
        library.recordRecentChannel(stream)
    }

    private func end() {
        hideTask?.cancel()
        for controller in players.tiles { controller.shutdown() }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func sceneChanged(active: Bool) {
        let quiet = 1 - audible
        players.tiles[audible].handleScenePhase(active: active)
        if !active {
            restInBackground = true
            players.tiles[quiet].stop()
        } else if restInBackground {
            restInBackground = false
            start(quiet)
        }
    }

    private func failover(for game: SportsGame, tile: Int) -> MobilePlaybackController.FailoverContext {
        let library = self.library
        return MobilePlaybackController.FailoverContext(
            plan: { library.failoverPlan(for: game) },
            urls: { id in library.stream(withID: id).map { library.playbackURLs(for: $0) } ?? [] },
            didSwitch: { channel in
                if let switched = library.stream(withID: channel.streamID) { streams[tile] = switched }
            },
            didPlay: { _ in })
    }
}

/// One picture of the two: the video, what it is, whether it is heard, and
/// what to do when it won't play.
private struct MobileMultiviewTile: View {
    @ObservedObject var controller: MobilePlaybackController
    let stream: XtreamStream
    let game: SportsGame?
    let audible: Bool
    let compact: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onRetry: () -> Void
    let onChooseChannel: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black
            MobileVideoSurface(controller: controller)
            // Over the video, which VLC draws into a view of its own that
            // doesn't reliably pass touches on.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onDoubleTap)
                .onTapGesture(perform: onTap)
            if let error = controller.error {
                VStack(spacing: 8) {
                    if !compact {
                        Text(error).font(.inter(12)).multilineTextAlignment(.center).lineLimit(3)
                        Text("Some providers allow one stream at a time.")
                            .font(.inter(11)).foregroundStyle(LineupStyle.mediaText.opacity(0.7))
                    }
                    HStack(spacing: 8) {
                        Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(LineupBarButtonStyle())
                        if let onChooseChannel {
                            Button("Channel", systemImage: "list.bullet", action: onChooseChannel)
                                .buttonStyle(LineupBarButtonStyle())
                        }
                    }
                }
                .padding(12)
                .lineupLiquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(10)
            } else if controller.loading {
                ProgressView().tint(LineupStyle.mediaText)
            }
            VStack {
                HStack(spacing: 6) {
                    Spacer()
                    Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(audible ? LineupStyle.onHighlight : LineupStyle.mediaText)
                        .frame(width: 26, height: 26)
                        .background(audible ? LineupStyle.highlight : Color.black.opacity(0.55), in: Circle())
                }
                Spacer()
                HStack {
                    // The channel, and the game by its teams -- never its
                    // score, which is ahead of the picture.
                    Text(game?.matchupLine ?? stream.name)
                        .font(.inter(compact ? 10 : 12, .bold)).lineLimit(1)
                        .foregroundStyle(LineupStyle.mediaText)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                    Spacer()
                }
            }
            .padding(8)
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(audible ? LineupStyle.highlight : Color.clear, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel((game?.matchupLine ?? stream.name) + (audible ? ", sound on" : ", muted"))
        .accessibilityAction(named: "Listen") { onTap() }
        .accessibilityAction(named: "Make large") { onDoubleTap() }
    }
}
