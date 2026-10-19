import Foundation
import UIKit
import Vision

/// Lines the stats up with the picture by reading the broadcast's own
/// scoreboard: its clock and score, a frame at a time, with Vision on the
/// phone. Nothing leaves the device and nothing needs a tap.
///
/// It runs while the stats are open on a live game whose feed has timed
/// plays (football, basketball, hockey, baseball, soccer), once a second
/// until enough readings agree and every few seconds after, to follow a
/// stream that reconnects. It rests while the phone is hot or the app is
/// in the background. A sync made by hand stands until the scoreboard
/// clearly says otherwise.
@MainActor
final class MobileAutoSync: ObservableObject {
    enum Status: Equatable {
        case off
        /// Watching the scoreboard; not enough readings agree yet.
        case reading
        /// The delay is the scoreboard's.
        case synced
    }

    static let enabledKey = "Lineup.stats.autoSync.v1"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { stop() }
        }
    }
    @Published private(set) var status: Status = .off

    private var loop: Task<Void, Never>?
    private var following: String?
    private var tracker: AutoSyncTracker?
    private var releaseFrames: (() -> Void)?

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Reads the scoreboard for the game `stats` follows, from the frames
    /// `frames` hands over. Asking again for the same game and channel
    /// changes nothing; another starts over.
    func run(for stats: MobileGameStats, channel: Int?,
             frames: @escaping @MainActor () async -> MobilePlaybackController.CapturedFrame?,
             release: @escaping @MainActor () -> Void) {
        guard isEnabled, let sport = stats.autoSyncSport, let teams = stats.autoSyncTeams,
              let game = stats.game else { stop(); return }
        let key = "\(game.id)|\(channel.map(String.init) ?? "")"
        guard key != following || loop == nil else { return }
        stop()
        following = key
        releaseFrames = release
        let clock = AutoSyncClock.forSport(sport)
        // A feed calls a football play after the snap the clock shows, so
        // its estimates run short; a scoreboard's score changes after the
        // play, so baseball's run long already.
        tracker = AutoSyncTracker(clock: clock, margin: sport == "football" ? 4 : (sport == "baseball" ? 0 : 1))
        status = .reading
        loop = Task { [weak self, weak stats] in
            while !Task.isCancelled {
                let settled = await self?.step(stats: stats, teams: teams, frames: frames) ?? false
                guard !Task.isCancelled, self != nil else { return }
                try? await Task.sleep(for: .seconds(settled ? 4 : 1))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        following = nil
        tracker = nil
        releaseFrames?()
        releaseFrames = nil
        status = .off
    }

    /// One frame, read and weighed. True once the delay is the scoreboard's.
    private func step(stats: MobileGameStats?, teams: (away: [String], home: [String]),
                      frames: @MainActor () async -> MobilePlaybackController.CapturedFrame?) async -> Bool {
        guard let stats, var tracker, let key = following else { return false }
        guard UIApplication.shared.applicationState == .active,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return status == .synced }
        // When it was on screen, and the viewer's own pauses then.
        let seenAt = Date()
        let lag = stats.playerLag()
        guard let frame = await frames() else { return status == .synced }
        let texts = await Self.read(FrameBox(frame: frame))
        // A new game or channel while the frame was read starts again.
        guard !Task.isCancelled, following == key else { return false }
        tracker.observe(clocks: ScoreboardReader.clocks(in: texts, maxMinutes: tracker.clock.maxMinutes),
                        score: ScoreboardReader.score(in: texts, away: teams.away, home: teams.home),
                        at: seenAt, playerLag: lag, plays: stats.autoSyncPlays)
        self.tracker = tracker
        guard let delay = tracker.delay else { return false }
        stats.applyAutoSync(delay)
        if status != .synced { status = .synced }
        return true
    }

    /// A frame handed to Vision's thread. The pixels are not touched again
    /// on this one.
    private struct FrameBox: @unchecked Sendable {
        let frame: MobilePlaybackController.CapturedFrame
    }

    /// Every line of text in the frame, where it is. Digits as they are:
    /// language correction would turn "0:45" into a word.
    nonisolated private static func read(_ box: FrameBox) async -> [ScoreboardText] {
        await Task.detached(priority: .utility) { () -> [ScoreboardText] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.015
            let handler: VNImageRequestHandler
            switch box.frame {
            case .pixelBuffer(let buffer): handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
            case .image(let image): handler = VNImageRequestHandler(cgImage: image, options: [:])
            }
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return ScoreboardText(text: text, x: box.minX, y: box.minY, width: box.width, height: box.height)
            }
        }.value
    }
}
