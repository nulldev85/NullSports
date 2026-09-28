import Foundation
import XCTest
@testable import ForgeCore

final class TimerProgramTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testTabataClassicStructure() {
        let program = TimerProgram(config: .standard(.tabata))
        // Get ready + 8 work + 7 rest (last rest skipped).
        XCTAssertEqual(program.phases.count, 1 + 8 + 7)
        XCTAssertEqual(program.phases.first?.kind, .prepare)
        XCTAssertEqual(program.workPhaseCount, 8)
        XCTAssertEqual(program.totalDuration, 10 + 8 * 20 + 7 * 10)
        XCTAssertEqual(program.workDuration, 230)
    }

    func testTabataKeepsLastRestWhenAsked() {
        var config = TimerConfig.standard(.tabata)
        config.skipLastRest = false
        config.leadIn = 0
        let program = TimerProgram(config: config)
        XCTAssertEqual(program.totalDuration, 240)
        XCTAssertEqual(program.phases.last?.kind, .rest)
    }

    func testMultiSetIntervalsUseSetRest() {
        var config = TimerConfig(kind: .intervals, rounds: 3, work: 40, rest: 20, sets: 2, restBetweenSets: 90, leadIn: 0)
        config.skipLastRest = true
        let program = TimerProgram(config: config)
        let kinds = program.phases.map(\.kind)
        XCTAssertEqual(kinds, [.work, .rest, .work, .rest, .work, .setRest, .work, .rest, .work, .rest, .work])
        XCTAssertEqual(program.phases[5].duration, 90)
        XCTAssertEqual(program.phases[6].set, 2)
        XCTAssertEqual(program.totalDuration, 6 * 40 + 4 * 20 + 90)
    }

    func testEmomRounds() {
        let config = TimerConfig(kind: .emom, interval: 90, rounds: 6, leadIn: 5)
        let program = TimerProgram(config: config)
        XCTAssertEqual(program.phases.count, 7)
        XCTAssertEqual(program.phases[3].label, "Round 3")
        XCTAssertEqual(program.phases[3].totalRounds, 6)
        XCTAssertEqual(program.totalDuration, 5 + 6 * 90)
    }

    func testDeathByIncrementsReps() {
        let config = TimerConfig(kind: .deathBy, interval: 60, rounds: 20, leadIn: 0, startReps: 2, repIncrement: 2)
        let program = TimerProgram(config: config)
        XCTAssertEqual(program.phases.prefix(3).compactMap(\.targetReps), [2, 4, 6])
        XCTAssertEqual(program.phases[2].label, "6 reps")
    }

    func testCustomSequenceRepeats() {
        let config = TimerConfig(
            kind: .custom,
            sets: 2,
            restBetweenSets: 30,
            segments: [
                IntervalSegment(name: "Sprint", duration: 20, kind: .work),
                IntervalSegment(name: "Jog", duration: 40, kind: .work),
                IntervalSegment(name: "Walk", duration: 60, kind: .rest),
            ],
            leadIn: 0,
            skipLastRest: true
        )
        let program = TimerProgram(config: config)
        XCTAssertEqual(program.phases.map(\.label), ["Sprint", "Jog", "Walk", "Set Rest", "Sprint", "Jog"])
        XCTAssertEqual(program.totalDuration, 20 + 40 + 60 + 30 + 20 + 40)
    }

    func testOpenEndedFormats() {
        XCTAssertNil(TimerProgram(config: .standard(.stopwatch)).totalDuration)
        var forTime = TimerConfig.standard(.forTime)
        forTime.duration = 0
        XCTAssertNil(TimerProgram(config: forTime).totalDuration)
        forTime.duration = 600
        XCTAssertEqual(TimerProgram(config: forTime).workDuration, 600)
    }

    func testSanitizeNeverProducesEmptyPrograms() {
        let broken = TimerConfig(kind: .custom, rounds: -3, work: -1, rest: -5, sets: 0, segments: [], leadIn: -10)
        let program = TimerProgram(config: broken)
        XCTAssertFalse(program.phases.isEmpty)
        XCTAssertTrue(program.phases.allSatisfy { ($0.duration ?? 1) > 0 })
        let emom = TimerProgram(config: TimerConfig(kind: .emom, interval: 0, rounds: 0))
        XCTAssertGreaterThan(emom.totalDuration ?? 0, 0)
    }

    func testSnapshotWalksThroughPhases() {
        let program = TimerProgram(config: .standard(.tabata))
        let run = TimerRun(config: program.config, startedAt: t0)

        var snap = program.snapshot(for: run, at: t0.addingTimeInterval(3))
        XCTAssertEqual(snap.phase.kind, .prepare)
        XCTAssertEqual(snap.phaseRemaining ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(snap.clockText, "0:07")

        snap = program.snapshot(for: run, at: t0.addingTimeInterval(10 + 5))
        XCTAssertEqual(snap.phase.kind, .work)
        XCTAssertEqual(snap.phase.round, 1)
        XCTAssertEqual(snap.workElapsed, 5, accuracy: 0.001)

        snap = program.snapshot(for: run, at: t0.addingTimeInterval(10 + 20 + 2))
        XCTAssertEqual(snap.phase.kind, .rest)
        XCTAssertEqual(snap.nextPhase?.round, 2)

        snap = program.snapshot(for: run, at: t0.addingTimeInterval(10 + 230 + 50))
        XCTAssertTrue(snap.isFinished)
        XCTAssertEqual(snap.phase.round, 8)
        XCTAssertEqual(snap.totalRemaining, 0)
    }

    func testPauseResumeExcludesPausedTime() {
        let program = TimerProgram(config: TimerConfig(kind: .countdown, duration: 60, leadIn: 0))
        var run = TimerRun(config: program.config, startedAt: t0)
        run.pause(at: t0.addingTimeInterval(10))
        XCTAssertTrue(run.isPaused)
        XCTAssertEqual(program.snapshot(for: run, at: t0.addingTimeInterval(500)).phaseRemaining ?? 0, 50, accuracy: 0.001)
        run.resume(at: t0.addingTimeInterval(500))
        XCTAssertEqual(program.snapshot(for: run, at: t0.addingTimeInterval(520)).phaseRemaining ?? 0, 30, accuracy: 0.001)
        // Double pause/resume calls are harmless.
        run.resume(at: t0.addingTimeInterval(521))
        XCTAssertEqual(program.snapshot(for: run, at: t0.addingTimeInterval(520)).phaseRemaining ?? 0, 30, accuracy: 0.001)
    }

    func testSkipAndPrevious() {
        let program = TimerProgram(config: TimerConfig(kind: .intervals, rounds: 3, work: 30, rest: 15, leadIn: 10))
        var run = TimerRun(config: program.config, startedAt: t0)
        let now = t0.addingTimeInterval(4)
        run.skipPhase(at: now, program: program)
        var snap = program.snapshot(for: run, at: now)
        XCTAssertEqual(snap.phase.kind, .work)
        XCTAssertEqual(snap.phaseElapsed, 0, accuracy: 0.001)

        run.skipPhase(at: now, program: program)
        snap = program.snapshot(for: run, at: now)
        XCTAssertEqual(snap.phase.kind, .rest)

        // Within 2 s of a phase start, "previous" goes back a phase…
        run.previousPhase(at: now.addingTimeInterval(1), program: program)
        snap = program.snapshot(for: run, at: now.addingTimeInterval(1))
        XCTAssertEqual(snap.phase.kind, .work)
        XCTAssertEqual(snap.phaseElapsed, 0, accuracy: 0.001)

        // …otherwise it restarts the current one.
        run.previousPhase(at: now.addingTimeInterval(11), program: program)
        snap = program.snapshot(for: run, at: now.addingTimeInterval(11))
        XCTAssertEqual(snap.phase.kind, .work)
        XCTAssertEqual(snap.phaseElapsed, 0, accuracy: 0.001)

        // Skipping past the last phase finishes the run.
        for _ in 0..<10 { run.skipPhase(at: now.addingTimeInterval(11), program: program) }
        XCTAssertTrue(run.isFinished)
    }

    func testAmrapResultCountsRoundTaps() {
        let program = TimerProgram(config: TimerConfig(kind: .amrap, duration: 600, leadIn: 10))
        var run = TimerRun(config: program.config, startedAt: t0)
        for minute in 1...7 {
            run.markRound(at: t0.addingTimeInterval(10 + Double(minute) * 80), program: program)
        }
        run.undoRound()
        XCTAssertEqual(run.roundSplits.count, 6)
        XCTAssertEqual(run.roundSplits.first ?? 0, 80, accuracy: 0.001)
        let end = t0.addingTimeInterval(700)
        run.finish(at: end, program: program)
        let result = program.result(for: run, at: end, extraReps: 12)
        XCTAssertEqual(result.rounds, 6)
        XCTAssertEqual(result.extraReps, 12)
        XCTAssertEqual(result.elapsed, 600, accuracy: 0.001)
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.summary(for: program.config), "6 rounds + 12 reps")
    }

    func testForTimeFinishedVersusCapped() {
        let program = TimerProgram(config: TimerConfig(kind: .forTime, duration: 900, rounds: 3, leadIn: 10))
        var fast = TimerRun(config: program.config, startedAt: t0)
        fast.finish(at: t0.addingTimeInterval(10 + 754), program: program)
        let fastResult = program.result(for: fast, at: t0.addingTimeInterval(2000))
        XCTAssertTrue(fastResult.finished)
        XCTAssertEqual(fastResult.elapsed, 754, accuracy: 0.001)
        XCTAssertEqual(fastResult.summary(for: program.config), "12:34")

        var capped = TimerRun(config: program.config, startedAt: t0)
        capped.markRound(at: t0.addingTimeInterval(400), program: program)
        let cappedResult = program.result(for: capped, at: t0.addingTimeInterval(5000), extraReps: 7)
        XCTAssertFalse(cappedResult.finished)
        XCTAssertEqual(cappedResult.elapsed, 900, accuracy: 0.001)
        XCTAssertEqual(cappedResult.summary(for: program.config), "Time cap · 1 rounds + 7 reps")
    }

    func testEmomResultCountsCompletedIntervals() {
        let program = TimerProgram(config: TimerConfig(kind: .emom, interval: 60, rounds: 10, leadIn: 0))
        var run = TimerRun(config: program.config, startedAt: t0)
        run.finish(at: t0.addingTimeInterval(4 * 60 + 30), program: program)
        let result = program.result(for: run, at: t0.addingTimeInterval(9999))
        XCTAssertEqual(result.rounds, 4, "the interval in progress when stopped doesn't count")
        XCTAssertFalse(result.finished)

        let full = TimerRun(config: program.config, startedAt: t0)
        let fullResult = program.result(for: full, at: t0.addingTimeInterval(10 * 60 + 5))
        XCTAssertEqual(fullResult.rounds, 10)
        XCTAssertTrue(fullResult.finished)
    }

    func testRunStateSurvivesEncoding() throws {
        let program = TimerProgram(config: .standard(.amrap))
        var run = TimerRun(config: program.config, startedAt: t0)
        run.markRound(at: t0.addingTimeInterval(100), program: program)
        run.pause(at: t0.addingTimeInterval(120))
        let text = try JSONCoding.encodeString(run)
        let decoded = try JSONCoding.decode(TimerRun.self, from: text)
        XCTAssertEqual(decoded, run)
        let later = t0.addingTimeInterval(5000)
        XCTAssertEqual(program.snapshot(for: decoded, at: later), program.snapshot(for: run, at: later))
    }
}

final class TimerCueTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func cues(_ program: TimerProgram, _ run: TimerRun, from a: Double, to b: Double) -> [TimerCue] {
        TimerCueDetector.cues(
            from: program.snapshot(for: run, at: t0.addingTimeInterval(a)),
            to: program.snapshot(for: run, at: t0.addingTimeInterval(b))
        )
    }

    func testCountdownTicksAndPhaseStarts() {
        let program = TimerProgram(config: .standard(.tabata))
        let run = TimerRun(config: program.config, startedAt: t0)
        XCTAssertEqual(TimerCueDetector.cues(from: nil, to: program.snapshot(for: run, at: t0)), [.phaseStart(program.phases[0])])
        XCTAssertEqual(cues(program, run, from: 6.95, to: 7.05), [.countdown(3)])
        XCTAssertEqual(cues(program, run, from: 7.95, to: 8.05), [.countdown(2)])
        XCTAssertEqual(cues(program, run, from: 8.95, to: 9.05), [.countdown(1)])
        XCTAssertEqual(cues(program, run, from: 9.95, to: 10.05), [.phaseStart(program.phases[1])])
        XCTAssertEqual(cues(program, run, from: 11, to: 12), [])
    }

    func testJumpingAcrossPhasesOnlyAnnouncesCurrent() {
        let program = TimerProgram(config: .standard(.tabata))
        let run = TimerRun(config: program.config, startedAt: t0)
        let result = cues(program, run, from: 12, to: 100)
        XCTAssertEqual(result.count, 1)
        guard case .phaseStart = result[0] else { return XCTFail("\(result)") }
    }

    func testFinishedFiresOnce() {
        let program = TimerProgram(config: TimerConfig(kind: .countdown, duration: 30, leadIn: 0))
        let run = TimerRun(config: program.config, startedAt: t0)
        XCTAssertEqual(cues(program, run, from: 29.9, to: 30.1), [.finished])
        XCTAssertEqual(cues(program, run, from: 30.1, to: 31), [])
    }

    func testLongPhaseAnnouncements() {
        let program = TimerProgram(config: TimerConfig(kind: .amrap, duration: 600, leadIn: 0))
        let run = TimerRun(config: program.config, startedAt: t0)
        XCTAssertEqual(cues(program, run, from: 299.9, to: 300.1), [.halfway])
        XCTAssertEqual(cues(program, run, from: 539.9, to: 540.1), [.remaining(60)])
        XCTAssertEqual(cues(program, run, from: 569.9, to: 570.1), [.remaining(30)])
        XCTAssertEqual(cues(program, run, from: 589.9, to: 590.1), [.remaining(10)])
    }

    func testStopwatchMinuteMarks() {
        let program = TimerProgram(config: TimerConfig(kind: .stopwatch, leadIn: 0))
        let run = TimerRun(config: program.config, startedAt: t0)
        XCTAssertEqual(cues(program, run, from: 59.9, to: 60.1), [.minuteMark(1)])
        XCTAssertEqual(cues(program, run, from: 60.1, to: 61), [])
    }
}
