import AVFoundation
import UIKit

/// Beeps, voice announcements and haptics for timers and rest periods.
///
/// Tones are synthesized in memory (no audio assets). While a timer runs the
/// player can keep an inaudible stream going so iOS lets the app keep
/// counting — and announcing — with the screen locked. Audio mixes with the
/// athlete's music rather than stopping it.
///
/// Everything that touches the audio hardware runs on its own queue (see
/// `CueOutput`): starting the audio session or engine can take a moment,
/// and a timer opening or a set being ticked off never waits for it.
@MainActor
final class CuePlayer {
    enum Tone: CaseIterable {
        case tick, go, rest, finish, restDone, round
    }

    enum Haptic {
        case light, medium, heavy, success, warning
    }

    private let output = CueOutput()
    // Kept and re-primed after each use, so countdown ticks land on time
    // instead of waiting for the Taptic Engine to wake.
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    private var holds = 0
    private var keepAliveHolds = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .ended else { return }
            MainActor.assumeIsolated { self?.recover() }
        })
        // The app's only engine is the cue engine.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        })
    }

    /// Builds the engine, tones and voice in the background ahead of the
    /// first cue (called once the app is on screen).
    func prepare() {
        output.prepare()
    }

    // MARK: Session lifetime

    /// Call when something that makes sound starts. With `keepAlive`, an
    /// inaudible stream keeps the app running in the background.
    func acquire(keepAlive: Bool) {
        idleStop?.cancel()
        holds += 1
        if keepAlive { keepAliveHolds += 1 }
        output.activate(keepAlive: keepAliveHolds > 0)
    }

    func release(keepAlive: Bool) {
        holds = max(0, holds - 1)
        if keepAlive { keepAliveHolds = max(0, keepAliveHolds - 1) }
        if keepAliveHolds == 0 { output.stopSilence() }
        if holds == 0 { output.deactivate(unlessSpeaking: false) }
    }

    private func recover() {
        guard holds > 0 else { return }
        output.activate(keepAlive: keepAliveHolds > 0)
    }

    // MARK: Output

    private var idleStop: Task<Void, Never>?

    /// For one-off sounds outside a timer: stop the engine and give the
    /// audio session back shortly afterwards.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled, self.holds == 0 else { return }
            self.output.deactivate(unlessSpeaking: true)
        }
    }

    func play(_ tone: Tone) {
        if holds == 0 {
            // A one-off sound (e.g. rest finished in the foreground).
            output.activate(keepAlive: false)
            scheduleIdleStop()
        }
        output.play(tone)
    }

    func speak(_ text: String) {
        if holds == 0 {
            output.activate(keepAlive: false)
            scheduleIdleStop()
        }
        output.speak(text)
    }

    func haptic(_ kind: Haptic) {
        switch kind {
        case .light:
            lightImpact.impactOccurred()
            lightImpact.prepare()
        case .medium:
            mediumImpact.impactOccurred()
            mediumImpact.prepare()
        case .heavy:
            heavyImpact.impactOccurred()
            heavyImpact.prepare()
        case .success:
            notification.notificationOccurred(.success)
            notification.prepare()
        case .warning:
            notification.notificationOccurred(.warning)
            notification.prepare()
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
}

/// The audio side of cues: the audio session, the engine, the tones and the
/// voice, all used on one serial queue in the order they're asked for.
/// Activating the session and starting the engine are blocking calls into
/// the audio system, so none of this runs on the main thread.
private final class CueOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nulldev85.Forge.cues", qos: .userInitiated)
    /// Built on first use; only touched on `queue`.
    private var built: CueRig?

    private var rig: CueRig {
        if let built { return built }
        let rig = CueRig()
        built = rig
        return rig
    }

    func prepare() {
        queue.async { [self] in _ = rig }
    }

    func activate(keepAlive: Bool) {
        queue.async { [self] in
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                // No audio route (e.g. some simulators): cues become silent,
                // timing is unaffected.
            }
            let rig = self.rig
            rig.startEngineIfNeeded()
            if keepAlive { rig.startSilence() }
        }
    }

    func stopSilence() {
        queue.async { [self] in built?.silence.stop() }
    }

    /// Stops the engine and gives the audio session back to other apps.
    /// With `unlessSpeaking`, an announcement still being spoken is left to
    /// finish.
    func deactivate(unlessSpeaking: Bool) {
        queue.async { [self] in
            guard let rig = built else { return }
            if unlessSpeaking, rig.synthesizer.isSpeaking { return }
            rig.player.stop()
            rig.engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func play(_ tone: CuePlayer.Tone) {
        queue.async { [self] in
            let rig = self.rig
            rig.startEngineIfNeeded()
            guard rig.engine.isRunning, let buffer = rig.buffers[tone] else { return }
            rig.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            if !rig.player.isPlaying { rig.player.play() }
        }
    }

    func speak(_ text: String) {
        queue.async { [self] in
            let synthesizer = rig.synthesizer
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            utterance.volume = 1
            utterance.prefersAssistiveTechnologySettings = false
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .word)
            }
            synthesizer.speak(utterance)
        }
    }
}

/// The engine with its two players (cues, and the inaudible keep-alive
/// stream), the synthesized tones and the speech voice.
private final class CueRig {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let silence = AVAudioPlayerNode()
    let synthesizer = AVSpeechSynthesizer()
    let buffers: [CuePlayer.Tone: AVAudioPCMBuffer]
    let silentBuffer: AVAudioPCMBuffer?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        var buffers: [CuePlayer.Tone: AVAudioPCMBuffer] = [:]
        buffers[.tick] = CueRig.makeTone([(880, 0.12, 0)], volume: 0.7, format: format)
        buffers[.go] = CueRig.makeTone([(1320, 0.42, 0)], volume: 0.8, format: format)
        buffers[.rest] = CueRig.makeTone([(660, 0.16, 0.08), (660, 0.16, 0)], volume: 0.75, format: format)
        buffers[.finish] = CueRig.makeTone([(1320, 0.14, 0.07), (1320, 0.14, 0.07), (1760, 0.5, 0)], volume: 0.85, format: format)
        buffers[.restDone] = CueRig.makeTone([(988, 0.1, 0.06), (1319, 0.22, 0)], volume: 0.8, format: format)
        buffers[.round] = CueRig.makeTone([(1175, 0.08, 0)], volume: 0.6, format: format)
        self.buffers = buffers
        let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
        silent?.frameLength = silent?.frameCapacity ?? 0
        silentBuffer = silent
        engine.attach(player)
        engine.attach(silence)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(silence, to: engine.mainMixerNode, format: format)
    }

    func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    func startSilence() {
        guard engine.isRunning, !silence.isPlaying, let silentBuffer else { return }
        silence.scheduleBuffer(silentBuffer, at: nil, options: .loops)
        silence.play()
    }

    // MARK: Synthesis

    private static func makeTone(_ segments: [(frequency: Double, duration: Double, gap: Double)], volume: Float, format: AVAudioFormat) -> AVAudioPCMBuffer? {
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
