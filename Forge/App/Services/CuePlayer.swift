import AVFoundation
import UIKit

/// Beeps, voice announcements and haptics for timers and rest periods.
///
/// Tones are synthesized in memory (no audio assets). While a timer runs the
/// player can keep an inaudible stream going so iOS lets the app keep
/// counting — and announcing — with the screen locked. Audio mixes with the
/// athlete's music rather than stopping it.
@MainActor
final class CuePlayer {
    enum Tone: CaseIterable {
        case tick, go, rest, finish, restDone, round
    }

    enum Haptic {
        case light, medium, heavy, success, warning
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let silence = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var buffers: [Tone: AVAudioPCMBuffer] = [:]
    private var silentBuffer: AVAudioPCMBuffer?
    private let synthesizer = AVSpeechSynthesizer()
    private var holds = 0
    private var keepAliveHolds = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.attach(silence)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(silence, to: engine.mainMixerNode, format: format)
        buffers[.tick] = makeTone([(880, 0.12, 0)], volume: 0.7)
        buffers[.go] = makeTone([(1320, 0.42, 0)], volume: 0.8)
        buffers[.rest] = makeTone([(660, 0.16, 0.08), (660, 0.16, 0)], volume: 0.75)
        buffers[.finish] = makeTone([(1320, 0.14, 0.07), (1320, 0.14, 0.07), (1760, 0.5, 0)], volume: 0.85)
        buffers[.restDone] = makeTone([(988, 0.1, 0.06), (1319, 0.22, 0)], volume: 0.8)
        buffers[.round] = makeTone([(1175, 0.08, 0)], volume: 0.6)
        silentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
        silentBuffer?.frameLength = silentBuffer?.frameCapacity ?? 0

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .ended else { return }
            MainActor.assumeIsolated { self?.recover() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        })
    }

    // MARK: Session lifetime

    /// Call when something that makes sound starts. With `keepAlive`, an
    /// inaudible stream keeps the app running in the background.
    func acquire(keepAlive: Bool) {
        idleStop?.cancel()
        holds += 1
        if keepAlive { keepAliveHolds += 1 }
        activate()
    }

    func release(keepAlive: Bool) {
        holds = max(0, holds - 1)
        if keepAlive { keepAliveHolds = max(0, keepAliveHolds - 1) }
        if keepAliveHolds == 0 { silence.stop() }
        if holds == 0 {
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // No audio route (e.g. some simulators): cues become silent,
            // timing is unaffected.
        }
        startEngineIfNeeded()
        if keepAliveHolds > 0 { startSilence() }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    private func startSilence() {
        guard engine.isRunning, !silence.isPlaying, let silentBuffer else { return }
        silence.scheduleBuffer(silentBuffer, at: nil, options: .loops)
        silence.play()
    }

    private func recover() {
        guard holds > 0 else { return }
        activate()
    }

    // MARK: Output

    private var idleStop: Task<Void, Never>?

    /// For one-off sounds outside a timer: stop the engine and give the
    /// audio session back shortly afterwards.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled, self.holds == 0, !self.synthesizer.isSpeaking else { return }
            self.player.stop()
            self.engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func play(_ tone: Tone) {
        if holds == 0 {
            // A one-off sound (e.g. rest finished in the foreground).
            activate()
            scheduleIdleStop()
        }
        startEngineIfNeeded()
        guard engine.isRunning, let buffer = buffers[tone] else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    func speak(_ text: String) {
        if holds == 0 {
            activate()
            scheduleIdleStop()
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.volume = 1
        utterance.prefersAssistiveTechnologySettings = false
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        synthesizer.speak(utterance)
    }

    func haptic(_ kind: Haptic) {
        switch kind {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    // MARK: Timer cues

    func perform(_ cue: TimerCue, config: TimerConfig, settings: AppSettings) {
        switch cue {
        case .countdown:
            if settings.timerBeeps { play(.tick) }
            if settings.timerHaptics { haptic(.light) }
        case .phaseStart(let phase):
            switch phase.kind {
            case .prepare:
                if settings.timerVoice { speak("Get ready") }
            case .work:
                if settings.timerBeeps { play(.go) }
                if settings.timerHaptics { haptic(.heavy) }
                if settings.timerVoice { speak(Self.announcement(for: phase, config: config)) }
            case .rest:
                if settings.timerBeeps { play(.rest) }
                if settings.timerHaptics { haptic(.medium) }
                if settings.timerVoice { speak(phase.label == "Rest" ? "Rest" : phase.label) }
            case .setRest:
                if settings.timerBeeps { play(.rest) }
                if settings.timerHaptics { haptic(.medium) }
                if settings.timerVoice { speak("Set complete. Rest.") }
            }
        case .halfway:
            if settings.timerVoice { speak("Halfway") }
        case .remaining(let seconds):
            guard settings.timerVoice, settings.timerAnnounceRemaining else { return }
            speak(seconds == 60 ? "One minute left" : "\(seconds) seconds")
        case .minuteMark(let minutes):
            guard settings.timerVoice, settings.timerAnnounceRemaining else { return }
            speak(minutes == 1 ? "One minute" : "\(minutes) minutes")
        case .finished:
            if settings.timerBeeps { play(.finish) }
            if settings.timerHaptics { haptic(.success) }
            if settings.timerVoice { speak("Time! Great work.") }
        }
    }

    static func announcement(for phase: TimerPhase, config: TimerConfig) -> String {
        switch config.kind {
        case .emom:
            if phase.totalRounds > 1, phase.round == phase.totalRounds { return "Last round" }
            return "Round \(phase.round)"
        case .deathBy:
            return "\(phase.targetReps ?? phase.round) reps"
        case .tabata, .intervals:
            if phase.round == phase.totalRounds, phase.set == phase.totalSets, phase.totalRounds > 1 { return "Last one" }
            return phase.totalSets > 1 && phase.round == 1 ? "Set \(phase.set). Work" : "Work"
        case .custom:
            return phase.label
        case .amrap, .forTime, .countdown, .stopwatch:
            return "Go"
        }
    }

    // MARK: Synthesis

    private func makeTone(_ segments: [(frequency: Double, duration: Double, gap: Double)], volume: Float) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = segments.reduce(0) { $0 + $1.duration + $1.gap }
        let frames = AVAudioFrameCount(total * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        var index = 0
        let ramp = 0.006 * rate
        for segment in segments {
            let toneFrames = Int(segment.duration * rate)
            for i in 0..<toneFrames where index < Int(frames) {
                let t = Double(i) / rate
                let attack = min(1, Double(i) / ramp)
                let release = min(1, Double(toneFrames - i) / ramp)
                let envelope = Float(min(attack, release))
                // A touch of the second harmonic makes it cut through music.
                let sample = sin(2 * .pi * segment.frequency * t) * 0.85 + sin(4 * .pi * segment.frequency * t) * 0.15
                channel[index] = Float(sample) * envelope * volume
                index += 1
            }
            let gapFrames = Int(segment.gap * rate)
            for _ in 0..<gapFrames where index < Int(frames) {
                channel[index] = 0
                index += 1
            }
        }
        while index < Int(frames) {
            channel[index] = 0
            index += 1
        }
        return buffer
    }
}
