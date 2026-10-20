import Foundation
import UIKit
import Vision

/// A frame of the picture on screen, as a player hands it over to be read.
enum CapturedVideoFrame {
    case pixelBuffer(CVPixelBuffer)
    case image(CGImage)
}

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
///
/// A scoreboard is a small box in a corner or along an edge, so the top and
/// bottom of the picture are read in turn, each at several times the size a
/// reading of the whole frame gives it, until a clock turns up; then only
/// the band it is in is read, until it has been gone a while (ads, replays).
@MainActor
final class MobileAutoSync: ObservableObject {
    enum Status: Equatable {
        case off
        /// Watching the scoreboard; not enough readings agree yet.
        case reading(Progress)
        /// Paused while the phone is hot.
        case resting
        /// The delay is the scoreboard's.
        case synced
    }

    /// How far a reading has got, so the viewer can see what it sees.
    enum Progress: Equatable {
        case starting
        /// The player has not handed over a picture for a while.
        case noPicture
        /// Pictures are read, with no scoreboard in them.
        case noScoreboard
        /// The scoreboard is read, and plays are being matched to it.
        case matching(clock: Int?, agreeing: Int, needed: Int)
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
    /// The band the scoreboard was last read in, read alone while it is there.
    private var area: ScoreboardArea?
    private var searchTurn = 0
    private var missedFrames = 0
    private var blankFrames = 0
    private var frameCount = 0
    private var sawScoreboardYet = false
    private var lastClock: Int?
    private var estimateCount = 0
    #if os(iOS)
    private let diagnostics = PlaybackDiagnostics.shared
    #endif

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Reads the scoreboard for the game `stats` follows, from the frames
    /// `frames` hands over. Asking again for the same game and channel
    /// changes nothing; another starts over.
    func run(for stats: MobileGameStats, channel: Int?,
             frames: @escaping @MainActor () async -> CapturedVideoFrame?,
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
        status = .reading(.starting)
        note("Auto Sync on: \(sport), \(teams.away.joined(separator: "/")) at \(teams.home.joined(separator: "/"))")
        loop = Task { [weak self, weak stats] in
            while !Task.isCancelled {
                let settled = await self?.step(stats: stats, teams: teams, frames: frames) ?? false
                guard !Task.isCancelled, self != nil else { return }
                try? await Task.sleep(for: .seconds(settled ? 4 : 1))
            }
        }
    }

    func stop() {
        if loop != nil { note("Auto Sync off") }
        loop?.cancel()
        loop = nil
        following = nil
        tracker = nil
        releaseFrames?()
        releaseFrames = nil
        area = nil
        searchTurn = 0
        missedFrames = 0
        blankFrames = 0
        frameCount = 0
        sawScoreboardYet = false
        lastClock = nil
        estimateCount = 0
        status = .off
    }

    /// One frame, read and weighed. True once the delay is the scoreboard's.
    private func step(stats: MobileGameStats?, teams: (away: [String], home: [String]),
                      frames: @MainActor () async -> CapturedVideoFrame?) async -> Bool {
        guard let stats, var tracker, let key = following else { return false }
        guard UIApplication.shared.applicationState == .active else { return status == .synced }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else {
            if status != .synced, status != .resting {
                status = .resting
                note("Auto Sync resting: the device is running hot")
            }
            return status == .synced
        }
        // When it was on screen, and the viewer's own pauses then.
        let seenAt = Date()
        let lag = stats.playerLag()
        guard let frame = await frames() else {
            missedFrames += 1
            if missedFrames == 5 { note("Auto Sync: the player hands over no picture") }
            if missedFrames >= 5 { show(.noPicture) }
            return status == .synced
        }
        missedFrames = 0
        frameCount += 1
        let place = area ?? ScoreboardArea.search[searchTurn % ScoreboardArea.search.count]
        if area == nil { searchTurn += 1 }
        let texts = await Self.read(FrameBox(frame: frame), in: place)
        // A new game or channel while the frame was read starts again.
        guard !Task.isCancelled, following == key else { return false }

        let clockLines = ScoreboardReader.clockLines(in: texts, maxMinutes: tracker.clock.maxMinutes)
        let clocks = Set(clockLines.map(\.seconds))
        let score = ScoreboardReader.score(in: texts, away: teams.away, home: teams.home)
        let sawScoreboard = tracker.clock == .none ? score != nil : !clocks.isEmpty
        if sawScoreboard {
            blankFrames = 0
            sawScoreboardYet = true
            if let first = clockLines.first { lastClock = first.seconds }
            let anchor = clockLines.first?.line
                ?? ScoreboardReader.line(in: texts, naming: teams.away + teams.home)
            if area == nil, let line = anchor {
                area = .around(line)
                note("Auto Sync found the scoreboard in \(Self.describe(place)): \"\(line.text)\"")
            }
        } else {
            blankFrames += 1
            if area != nil, blankFrames >= 8 {
                area = nil
                note("Auto Sync lost the scoreboard; looking again")
            }
        }
        tracker.observe(clocks: clocks, score: score, at: seenAt, playerLag: lag, plays: stats.autoSyncPlays)
        self.tracker = tracker
        record(frame: frame, place: place, texts: texts, clocks: clocks, score: score, tracker: tracker)

        if let delay = tracker.delay {
            stats.applyAutoSync(delay)
            if status != .synced {
                status = .synced
                note("Auto Sync locked: the picture is \(Int(delay))s behind live")
            }
            return true
        }
        if blankFrames >= 8 || (!sawScoreboardYet && frameCount >= 6) {
            show(.noScoreboard)
        } else if sawScoreboardYet {
            show(.matching(clock: lastClock, agreeing: tracker.agreeing, needed: tracker.needed))
        } else {
            show(.starting)
        }
        return false
    }

    /// What it is doing, until it has synced: a lock is not undone by a
    /// moment without a scoreboard.
    private func show(_ progress: Progress) {
        guard status != .synced, status != .reading(progress) else { return }
        // The clock it shows moves every few seconds, not every frame: each
        // change redraws the Sports tab.
        if case .reading(.matching(let shown?, let agreeing, let needed)) = status,
           case .matching(let clock?, agreeing, needed) = progress, abs(clock - shown) < 5 { return }
        status = .reading(progress)
    }

    /// A line in the playback log. The iPhone's is switched on to chase a
    /// problem and takes every step; the television's is kept between
    /// launches, so it takes only the moments that matter.
    private func note(_ text: @autoclosure () -> String) {
        #if os(iOS)
        diagnostics.record(text())
        #else
        PlaybackJournal.shared.note(text())
        #endif
    }

    /// The playback log's account of a frame, while it is switched on: every
    /// fifth frame, and any frame that found nothing or made an estimate.
    private func record(frame: CapturedVideoFrame, place: ScoreboardArea, texts: [ScoreboardText],
                        clocks: Set<Int>, score: (away: Int, home: Int)?, tracker: AutoSyncTracker) {
        #if os(iOS)
        guard diagnostics.isEnabled else { return }
        // Estimates are matched afresh each frame, as late plays arrive.
        if tracker.estimates.count != estimateCount {
            estimateCount = tracker.estimates.count
            let values = tracker.estimates.suffix(8).map { "\(Int($0.delay.rounded()))s" }.joined(separator: " ")
            note("Auto Sync estimates: \(estimateCount) (latest \(values)), \(tracker.agreeing) of \(tracker.needed) agree")
        }
        guard frameCount <= 3 || frameCount % 5 == 0 || clocks.isEmpty && score == nil else { return }
        var line = "Auto Sync frame \(frameCount): \(Self.describe(frame)), \(Self.describe(place)), \(texts.count) lines"
        if !clocks.isEmpty { line += ", clock " + clocks.sorted().map(Self.clock).joined(separator: "/") }
        if let score { line += ", score \(score.away)-\(score.home)" }
        if clocks.isEmpty && score == nil && !texts.isEmpty {
            line += ", read " + texts.prefix(6).map { "\"\($0.text.prefix(28))\"" }.joined(separator: " ")
        }
        note(line)
        #endif
    }

    /// "9:12", "67:13".
    nonisolated static func clock(_ seconds: Int) -> String {
        let rest = seconds % 60
        return "\(seconds / 60):\(rest < 10 ? "0" : "")\(rest)"
    }

    nonisolated private static func describe(_ place: ScoreboardArea) -> String {
        switch place {
        case .whole: return "the whole frame"
        case .top: return "the top of the frame"
        case .bottom: return "the bottom of the frame"
        default: return String(format: "the band %.0f-%.0f%% up", place.y * 100, (place.y + place.height) * 100)
        }
    }

    nonisolated private static func describe(_ frame: CapturedVideoFrame) -> String {
        switch frame {
        case .pixelBuffer(let buffer):
            let code = CVPixelBufferGetPixelFormatType(buffer)
            let characters = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
            let format = characters.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " }
                ? String(characters) : String(code, radix: 16)
            return "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) \(format)"
        case .image(let image):
            return "\(image.width)x\(image.height) snapshot"
        }
    }

    /// A frame handed to Vision's thread. The pixels are not touched again
    /// on this one.
    private struct FrameBox: @unchecked Sendable {
        let frame: CapturedVideoFrame
    }

    /// Every line of text in that part of the frame, placed in the whole
    /// frame. Digits as they are: language correction would turn "0:45"
    /// into a word.
    nonisolated private static func read(_ box: FrameBox, in place: ScoreboardArea) async -> [ScoreboardText] {
        await Task.detached(priority: .utility) { () -> [ScoreboardText] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.015
            request.regionOfInterest = CGRect(x: place.x, y: place.y, width: place.width, height: place.height)
            let handler: VNImageRequestHandler
            switch box.frame {
            case .pixelBuffer(let buffer): handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
            case .image(let image): handler = VNImageRequestHandler(cgImage: image, options: [:])
            }
            guard (try? handler.perform([request])) != nil else { return [] }
            // Vision gives each box within the part it read.
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return place.placing(ScoreboardText(text: text, x: box.minX, y: box.minY,
                                                    width: box.width, height: box.height))
            }
        }.value
    }
}
