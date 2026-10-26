import Foundation

@main
struct MobilePlaybackPolicyChecks {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }

        let recordingStart = Date(timeIntervalSince1970: 1200)
        let sixSeconds = recordingStart.addingTimeInterval(6)
        check(MobileRecordingSeekPolicy.providerStart(target: sixSeconds.addingTimeInterval(10), current: sixSeconds) == nil,
              "A ten-second forward skip must never reopen the same minute at its beginning")
        check(MobileRecordingSeekPolicy.providerStart(target: sixSeconds.addingTimeInterval(70), current: sixSeconds)
              == recordingStart.addingTimeInterval(60), "An unavailable native seek can reopen a later minute")
        check(MobileRecordingSeekPolicy.providerStart(target: recordingStart, current: sixSeconds) == recordingStart,
              "Deliberate rewind to the beginning remains available")
        check(MobileRecordingSeekPolicy.providerStart(target: sixSeconds, current: sixSeconds) == nil,
              "An unchanged drag must not restart the open minute")

        // Engine selection -------------------------------------------------
        let hls = URL(string: "http://example.com/live/user/pass/1234.m3u8")!
        let ts = URL(string: "http://example.com/live/user/pass/1234.ts")!
        let tokened = URL(string: "http://example.com/live/user/pass/1234.m3u8?token=abc&x=.ts")!
        let odd = URL(string: "http://example.com/live/user/pass/1234")!

        check(MobileEngineSelection.engine(for: hls) == .system, "HLS opens in AVPlayer")
        check(MobileEngineSelection.engine(for: ts) == .aether, "Transport streams open in AetherEngine")
        check(MobileEngineSelection.engine(for: tokened) == .system,
              "A query string does not change the engine")
        check(MobileEngineSelection.engine(for: odd) == .aether,
              "Extensionless server routes use AetherEngine")
        check(MobileEngineSelection.engine(for: URL(string: "http://e.com/a/1234.M3U8")!) == .system,
              "Extension matching ignores case")

        // Ordering: HLS first, so Picture in Picture is reachable, with the
        // transport stream still queued behind it as the fallback.
        let ordered = MobileEngineSelection.ordered([ts, hls])
        check(ordered == [hls, ts], "HLS is tried before the transport stream")
        check(MobileEngineSelection.ordered([hls, ts]) == [hls, ts], "Already-ordered input is unchanged")
        check(MobileEngineSelection.ordered([ts]) == [ts], "A VLC-only channel still has a candidate")
        check(MobileEngineSelection.ordered([]).isEmpty, "No candidates stays empty")

        // Stability: two HLS variants keep the provider's own preference order.
        let alt = URL(string: "http://example.com/live/user/pass/5678.m3u8")!
        check(MobileEngineSelection.ordered([hls, ts, alt]) == [hls, alt, ts],
              "Relative order inside each group is preserved")

        check(MobileEngineSelection.canPictureInPicture([ts, hls]), "A channel with HLS can offer PiP")
        check(MobileEngineSelection.canPictureInPicture([ts]), "Raw transport streams can offer PiP through Aether")
        check(MobileEngineSelection.engine(for: hls, preference: .aether) == .aether, "An explicit Aether choice applies to HLS")
        check(MobileEngineSelection.engine(for: ts, preference: .vlc) == .vlc, "An explicit VLC choice is honored")
        check(!MobileEngineSelection.canPictureInPicture([ts], preference: .vlc), "VLC has no PiP source")
        check(MobileEngineSelection.engine(for: hls, failed: [.system]) == .aether, "Native HLS failure still tries PiP-capable Aether")
        check(MobileEngineSelection.engine(for: hls, failed: [.system, .aether]) == .vlc, "VLC is the final fallback")
        check(MobileEngineSelection.engine(for: hls, failed: [.system, .aether, .vlc]) == nil, "Exhaustion cannot loop")
        check(!MobileEngineSelection.canPictureInPicture([]), "No candidates cannot offer PiP")

        check(MobilePlaybackPreference.allCases == [.native, .aether, .vlc, .mpv], "Native replaces Automatic in Settings")
        check(MobileEngineSelection.engine(for: ts, preference: .native, nativeFallback: false) == .aether,
              "Strict Native retains the demux/remux compatibility layer")
        check(MobileEngineSelection.engine(for: hls, preference: .native, failed: [.system, .aether], nativeFallback: false) == nil,
              "Strict Native cannot silently choose another decoder")
        check(MobileEngineSelection.engine(for: ts, preference: .native, failed: [.aether], nativeFallback: true) == .vlc,
              "Opted-in compatibility exhaustion retains the bounded fallback ladder")

        // Background policy ------------------------------------------------
        func action(background: Bool, pip: Bool = false, paused: Bool = false,
                    backgroundAudio: Bool = true) -> MobilePlaybackPhaseAction {
            MobileBackgroundPolicy.action(enteringBackground: background,
                                          pictureInPictureActive: pip,
                                          pausedByUser: paused,
                                          backgroundAudioEnabled: backgroundAudio)
        }

        // The regression this whole change exists to prevent.
        check(action(background: true) == .keepPlaying,
              "Backgrounding alone never stops playback")
        check(action(background: true, pip: true) == .keepPlaying,
              "PiP keeps playing while the app is backgrounded")
        check(action(background: false) == .keepPlaying, "Returning to the app resumes")

        // A viewer's pause outranks every automatic rule, in both directions.
        check(action(background: true, paused: true) == .leaveAsIs,
              "A paused stream stays paused when backgrounded")
        check(action(background: false, paused: true) == .leaveAsIs,
              "Returning to the app does not restart what the viewer paused")
        check(action(background: true, pip: true, paused: true) == .leaveAsIs,
              "Pausing inside the PiP window is respected")

        // Without the entitlement iOS suspends the process regardless, so a
        // clean pause beats being killed mid-buffer.
        check(action(background: true, backgroundAudio: false) == .pause,
              "Without the background audio mode, backgrounding pauses")
        check(action(background: true, pip: true, backgroundAudio: false) == .keepPlaying,
              "PiP holds the app alive even if background audio is off")
        check(action(background: false, backgroundAudio: false) == .keepPlaying,
              "Foreground playback never depends on the background audio mode")

        // System engine watchdog ------------------------------------------
        func verdict(_ elapsed: TimeInterval, ready: Bool, video: Bool) -> SystemEngineWatchdog.Verdict {
            SystemEngineWatchdog.verdict(elapsed: elapsed, isReady: ready, hasVideo: video)
        }

        // A healthy stream is never interrupted, however long it runs.
        check(verdict(0, ready: true, video: true) == .wait, "A ready stream with video waits")
        check(verdict(3600, ready: true, video: true) == .wait, "…and keeps waiting forever")

        // The captured failure: status stuck at unknown, no error, nothing to
        // fire on, and a perfectly good transport stream queued behind it.
        check(verdict(1, ready: false, video: false) == .wait, "A slow open is given time")
        check(verdict(7.9, ready: false, video: false) == .wait, "…right up to the deadline")
        check(verdict(8.1, ready: false, video: false) == .failOver, "An item that never loads falls over")
        check(SystemEngineWatchdog.readyDeadline == 8, "The open deadline is deliberate")

        // Ready but blank gets longer, because the server did answer.
        check(verdict(9, ready: true, video: false) == .wait, "A ready stream is given longer to show a picture")
        check(verdict(12.1, ready: true, video: false) == .failOver, "…but not indefinitely")
        check(SystemEngineWatchdog.videoDeadline == 12, "The picture deadline is deliberate")
        check(SystemEngineWatchdog.videoDeadline > SystemEngineWatchdog.readyDeadline,
              "Answering the request buys more patience than not answering it")

        // Video without readiness cannot happen, but must not crash the table.
        check(verdict(20, ready: false, video: true) == .failOver, "Unready outranks a stale size")

        // Starting together -------------------------------------------------
        check(StartTogether.frames(after: 0, lastFrameAt: nil, now: 10) == 1, "The first new frame starts a run")
        check(StartTogether.frames(after: 1, lastFrameAt: 10, now: 10.04) == 2, "A frame soon after extends it")
        check(StartTogether.frames(after: 2, lastFrameAt: 10, now: 10.6) == 1,
              "A frame long after a held one starts the run again")
        check(StartTogether.framesToStart >= 2, "One frame alone never counts as moving")

        check(!StartTogether.shouldTryNext(heldFor: nil, isLive: true, hasAnotherStream: true),
              "Nothing playing yet is not a held start")
        check(!StartTogether.shouldTryNext(heldFor: 3.9, isLive: true, hasAnotherStream: true),
              "A held start is given a moment")
        check(StartTogether.shouldTryNext(heldFor: 4.1, isLive: true, hasAnotherStream: true),
              "…then the channel's other stream is tried")
        check(!StartTogether.shouldTryNext(heldFor: 30, isLive: true, hasAnotherStream: false),
              "With nothing else to try, the start waits for its picture")
        check(!StartTogether.shouldTryNext(heldFor: 30, isLive: false, hasAnotherStream: true),
              "A title seeking to its place is never abandoned for being slow")
        check(StartTogether.stillPictureDeadline < SystemEngineWatchdog.videoDeadline,
              "A held picture is given up on sooner than a missing one")

        for age in [0.0, 2, 8, 29.9] {
            check(!MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: false, hasShownPicture: false, age: age),
                  "A movie opening is not a stopped input at \(age)s")
        }
        check(MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: false, hasShownPicture: false, age: 30), "Movie startup remains bounded")
        check(MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: true, hasShownPicture: false, age: 8), "Live stopped-input deadline is retained")
        check(MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: false, hasShownPicture: true, age: 2), "An actual playback stop still recovers")
        check(!StartTogether.canRevealVLC(displayedPictures: 0, settled: false, outputAge: 30), "Output allocation is not a displayed frame")
        check(StartTogether.canRevealVLC(displayedPictures: 1, settled: false, outputAge: 2.1), "A real frame can leave the shape deadline")
        check(!StartTogether.canReleaseAudioOnly(heldFor: 20, hasAudio: true, hasVideo: true), "Known video must not release sound alone")
        check(StartTogether.canReleaseAudioOnly(heldFor: 6, hasAudio: true, hasVideo: false), "Audio-only sources retain their fallback")
        var presentation = MobilePlaybackPresentation()
        check(presentation.loadingMessage(waitingForPicture: false) == "Opening stream…", "A new source opens")
        presentation.presentedVideo()
        check(presentation.loadingMessage(waitingForPicture: false) == "Buffering…", "A playing title buffers")
        presentation.beganRecovery()
        check(presentation.loadingMessage(waitingForPicture: false) == "Reconnecting…", "A retry reconnects")
        presentation.presentedVideo()
        check(!presentation.recovering, "A new picture ends recovery")
        print("Mobile playback policy checks passed")
    }
}
