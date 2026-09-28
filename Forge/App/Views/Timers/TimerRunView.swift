import SwiftUI

/// Full-screen timer display used for standalone timers and timed blocks.
struct TimerRunView: View {
    let controller: TimerController
    var saveTitle = "Save"
    let onSave: () -> Void
    let onMinimize: () -> Void
    let onDiscard: () -> Void
    var notes: Binding<String>?

    @State private var confirmStop = false
    @State private var confirmDiscard = false

    var body: some View {
        let snapshot = controller.snapshot
        let finished = controller.isFinished
        let color = finished ? Color.accentColor : Theme.color(for: snapshot.phase.kind)
        ZStack {
            LinearGradient(colors: [color.opacity(0.9), color.opacity(0.55), Color.black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: snapshot.phase.kind)
            VStack(spacing: 16) {
                topBar
                if finished {
                    resultPanel
                } else {
                    runningContent(snapshot, color: color)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .foregroundStyle(.white)
        }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
        .confirmationDialog("End this timer?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("End and Log Result") { controller.finishNow() }
            Button("Discard", role: .destructive) { onDiscard() }
            Button("Keep Going", role: .cancel) {}
        }
        .confirmationDialog("Discard this result?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onDiscard() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Minimize timer")
            Spacer()
            Text(controller.title)
                .font(.headline)
            Spacer()
            Button {
                if controller.isFinished {
                    confirmDiscard = true
                } else {
                    confirmStop = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("End timer")
            .accessibilityIdentifier("endTimer")
        }
    }

    @ViewBuilder
    private func runningContent(_ snapshot: TimerSnapshot, color: Color) -> some View {
        let kind = controller.program.config.kind
        VStack(spacing: 6) {
            Text(phaseTitle(snapshot))
                .font(.title3.weight(.heavy))
                .tracking(2)
                .textCase(.uppercase)
            if let roundText = roundText(snapshot) {
                Text(roundText)
                    .font(.subheadline.weight(.semibold))
                    .opacity(0.85)
            }
        }
        .padding(.top, 8)

        ZStack {
            ProgressRing(progress: snapshot.phase.duration == nil ? 1 : snapshot.phaseProgress, color: .white, lineWidth: 12)
                .opacity(0.9)
            VStack(spacing: 4) {
                Text(snapshot.clockText)
                    .font(.system(size: 84, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText(countsDown: !snapshot.phase.countsUp))
                    .animation(.default, value: snapshot.clockText)
                if let reps = snapshot.phase.targetReps {
                    Text("\(reps) reps")
                        .font(.title3.weight(.bold))
                }
                if let total = snapshot.totalRemaining, snapshot.phase.kind != .prepare {
                    Text("\(DurationFormat.countdownClock(total)) left")
                        .font(.subheadline.monospacedDigit())
                        .opacity(0.8)
                }
                if snapshot.isPaused {
                    Text("PAUSED")
                        .font(.caption.weight(.heavy))
                        .tracking(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
            }
            .padding(30)
        }
        .frame(maxWidth: 320, maxHeight: 320)
        .accessibilityElement(children: .combine)

        if let next = snapshot.nextPhase {
            Text("Next: \(next.label)\(next.duration.map { " · \(DurationFormat.clock($0))" } ?? "")")
                .font(.subheadline.weight(.medium))
                .opacity(0.8)
        }

        if !controller.movements.isEmpty {
            movementsList(snapshot)
        }

        Spacer(minLength: 0)

        if kind.countsRounds || kind == .stopwatch {
            roundCounter(kind: kind, snapshot: snapshot)
        }

        controls(kind: kind, snapshot: snapshot)
    }

    private func movementsList(_ snapshot: TimerSnapshot) -> some View {
        let config = controller.program.config
        let alternating = config.alternateMovements && controller.movements.count > 1
        let current = snapshot.phase.kind == .work ? snapshot.phase.workIndex % max(1, controller.movements.count) : -1
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(controller.movements.enumerated()), id: \.offset) { index, movement in
                HStack {
                    Text(movement.name)
                        .font(.subheadline.weight(alternating && index == current ? .bold : .medium))
                    Spacer()
                    if let detail = movement.detail {
                        Text(detail)
                            .font(.subheadline.monospacedDigit())
                            .opacity(0.85)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(alternating && index == current ? 0.28 : 0.12))
                )
            }
        }
    }

    private func roundCounter(kind: TimerKind, snapshot: TimerSnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(kind == .stopwatch ? "LAPS" : "ROUNDS")
                    .font(.caption.weight(.heavy))
                    .opacity(0.8)
                Text("\(snapshot.roundsCompleted)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Button {
                controller.undoRound()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.headline)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .disabled(snapshot.roundsCompleted == 0)
            .accessibilityLabel("Undo round")
            Button {
                controller.markRound()
            } label: {
                Label(kind == .stopwatch ? "Lap" : "Round", systemImage: "plus")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.25)))
            }
            .disabled(snapshot.phase.kind == .prepare)
            .accessibilityIdentifier("markRound")
        }
    }

    private func controls(kind: TimerKind, snapshot: TimerSnapshot) -> some View {
        HStack(spacing: 18) {
            circleButton("backward.fill", label: "Previous interval") { controller.back() }
            Button {
                controller.togglePause()
            } label: {
                Image(systemName: snapshot.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(.white))
            }
            .accessibilityLabel(snapshot.isPaused ? "Resume" : "Pause")
            .accessibilityIdentifier("pauseTimer")
            if kind == .forTime || kind == .stopwatch || kind == .deathBy || kind == .amrap {
                circleButton("flag.checkered", label: kind == .forTime ? "Done" : "Stop") { controller.finishNow() }
            } else {
                circleButton("forward.fill", label: "Next interval") { controller.skip() }
            }
        }
        .padding(.bottom, 8)
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(.white.opacity(0.18)))
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .opacity(0.85)
            }
        }
        .accessibilityLabel(label)
    }

    // MARK: Finished

    private var resultPanel: some View {
        let config = controller.program.config
        let result = controller.result()
        return ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 54, weight: .bold))
                    .padding(.top, 20)
                Text(result.summary(for: config))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                Text(config.summary)
                    .font(.subheadline)
                    .opacity(0.8)

                VStack(spacing: 12) {
                    if config.kind.countsRounds || config.kind == .deathBy {
                        resultStepper(title: config.kind == .deathBy ? "Rounds completed" : "Rounds", value: Binding(
                            get: { config.kind == .deathBy ? result.rounds : controller.run.roundSplits.count },
                            set: { newValue in
                                if config.kind != .deathBy { controller.setRounds(newValue) }
                            }
                        ), editable: config.kind != .deathBy)
                    }
                    if config.kind == .amrap || (config.kind == .forTime && !result.finished) {
                        resultStepper(title: "Extra reps", value: Binding(
                            get: { controller.extraReps },
                            set: { controller.extraReps = max(0, $0) }
                        ), editable: true)
                    }
                    if !controller.laps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(config.kind == .stopwatch ? "LAPS" : "ROUND SPLITS")
                                .font(.caption.weight(.heavy))
                                .opacity(0.8)
                            ForEach(Array(controller.laps.enumerated()), id: \.offset) { index, lap in
                                HStack {
                                    Text("\(index + 1)")
                                        .opacity(0.7)
                                    Spacer()
                                    Text(DurationFormat.clock(lap))
                                        .monospacedDigit()
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.12)))
                    }
                    if let notes {
                        TextField("Notes", text: notes, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                    }
                }

                Button(action: onSave) {
                    Text(saveTitle)
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
                }
                .accessibilityIdentifier("saveTimerResult")
                Button("Discard", role: .destructive) { confirmDiscard = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.bottom, 20)
        }
    }

    private func resultStepper(title: String, value: Binding<Int>, editable: Bool) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            if editable {
                Button { value.wrappedValue -= 1 } label: {
                    Image(systemName: "minus")
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.18)))
                }
            }
            Text("\(value.wrappedValue)")
                .font(.title2.weight(.bold).monospacedDigit())
                .frame(minWidth: 50)
            if editable {
                Button { value.wrappedValue += 1 } label: {
                    Image(systemName: "plus")
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.18)))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.12)))
    }

    // MARK: Text

    private func phaseTitle(_ snapshot: TimerSnapshot) -> String {
        switch snapshot.phase.kind {
        case .prepare: return "Get Ready"
        case .rest: return snapshot.phase.label == "Rest" ? "Rest" : snapshot.phase.label
        case .setRest: return "Set Rest"
        case .work:
            let kind = controller.program.config.kind
            switch kind {
            case .custom: return snapshot.phase.label
            case .emom: return "Work"
            case .deathBy: return "Round \(snapshot.phase.round)"
            default: return kind == .tabata || kind == .intervals ? "Work" : kind.displayName
            }
        }
    }

    private func roundText(_ snapshot: TimerSnapshot) -> String? {
        let phase = snapshot.phase
        guard phase.kind != .prepare else { return nil }
        var parts: [String] = []
        if phase.totalRounds > 0, controller.program.config.kind != .forTime {
            parts.append("Round \(phase.round) of \(phase.totalRounds)")
        } else if controller.program.config.kind == .forTime, phase.totalRounds > 0 {
            parts.append("Target \(phase.totalRounds) rounds")
        }
        if phase.totalSets > 1 {
            parts.append("Set \(phase.set) of \(phase.totalSets)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The Timers-tab timer, presented full screen.
struct StandaloneTimerScreen: View {
    let controller: TimerController
    @Environment(AppModel.self) private var app
    @State private var notes = ""

    var body: some View {
        TimerRunView(
            controller: controller,
            saveTitle: "Save to History",
            onSave: { app.timers.saveResult(notes: notes, extraReps: controller.extraReps) },
            onMinimize: { app.timers.isPresented = false },
            onDiscard: { app.timers.close() },
            notes: $notes
        )
    }
}
