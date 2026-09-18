import Foundation

@main
struct MobilePlaybackPolicyChecks {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }

        // Engine selection -------------------------------------------------
        let hls = URL(string: "http://example.com/live/user/pass/1234.m3u8")!
        let ts = URL(string: "http://example.com/live/user/pass/1234.ts")!
        let tokened = URL(string: "http://example.com/live/user/pass/1234.m3u8?token=abc&x=.ts")!
        let odd = URL(string: "http://example.com/live/user/pass/1234")!

        check(MobileEngineSelection.engine(for: hls) == .system, "HLS opens in AVPlayer")
        check(MobileEngineSelection.engine(for: ts) == .vlc, "Transport streams open in VLC")
        check(MobileEngineSelection.engine(for: tokened) == .system,
              "A query string does not change the engine")
        check(MobileEngineSelection.engine(for: odd) == .vlc,
              "An extensionless URL falls back to VLC rather than guessing")
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
        check(!MobileEngineSelection.canPictureInPicture([ts]), "A VLC-only channel cannot offer PiP")
        check(!MobileEngineSelection.canPictureInPicture([]), "No candidates cannot offer PiP")

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

        print("Mobile playback policy checks passed")
    }
}
