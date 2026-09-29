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
        let display = controller.display
        let finished = controller.isFinished
        let color = finished ? Color.accentColor : Theme.color(for: display.phase.kind)
        ZStack {
            Theme.night
                .ignoresSafeArea()
            // A soft glow in the phase's color instead of a full-bleed fill.
            RadialGradient(colors: [color.opacity(0.42), color.opacity(0.10), .clear], center: .top, startRadius: 10, endRadius: 560)
                .ignoresSafeArea()
                .animation(Motion.gentle, value: color)
            VStack(spacing: 16) {
                topBar
                if finished {
                    resultPanel
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    runningContent(display, color: color)
                        .transition(.opacity)
                }
            }
            .animation(Motion.smooth, value: finished)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .foregroundStyle(Theme.ink)
        }
        // Resolve every adaptive color in its dark variant, whatever the
        // presentation's appearance.
        .environment(\.colorScheme, .dark)
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
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassCircle(fallbackOpacity: 0.07)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Minimize timer")
            Spacer()
            Text(controller.title)
                .font(.app(.headline))
            Spacer()
            Button {
                if controller.isFinished {
                    confirmDiscard = true
                } else {
                    confirmStop = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassCircle(fallbackOpacity: 0.07)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("End timer")
            .accessibilityIdentifier("endTimer")
        }
    }

    private func runningContent(_ display: TimerDisplay, color: Color) -> some View {
        let kind = controller.program.config.kind
        return VStack(spacing: 16) {
            VStack(spacing: 6) {
                // Each phase's title slides in over the last one.
                ZStack {
                    Text(phaseTitle(display))
                        .font(.num(.subheadline, .medium))
                        .tracking(2.5)
                        .textCase(.uppercase)
                        .foregroundStyle(color)
                        .id(display.phaseIndex)
                        .transition(.push(from: .bottom).combined(with: .opacity))
                }
                .clipped()
                if let roundText = roundText(display) {
                    Text(roundText)
                        .font(.app(.subheadline, .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.top, 8)

            ZStack {
                TimerRing(controller: controller, color: color)
                    .opacity(display.isPaused ? 0.45 : 1)
                VStack(spacing: 6) {
                    Text(display.clockText)
                        .font(.num(size: 86, .light))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .contentTransition(.numericText(countsDown: !display.phase.countsUp))
                        .opacity(display.isPaused ? 0.55 : 1)
                    if let reps = display.phase.targetReps {
                        Text("\(reps) reps")
                            .font(.app(.title3, .semibold))
                            .contentTransition(.numericText())
                    }
                    if let remaining = display.remainingText, display.phase.kind != .prepare {
                        Text("\(remaining) left")
                            .font(.num(.subheadline))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(countsDown: true))
                    }
                    if display.isPaused {
                        Text("Paused")
                            .eyebrow()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .phaseAnimator([1.0, 0.45]) { content, opacity in
                                content.opacity(opacity)
                            } animation: { _ in
                                .easeInOut(duration: 1.1)
                            }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(30)
            }
            .frame(maxWidth: 320, maxHeight: 320)
            .accessibilityElement(children: .combine)

            if let next = display.nextPhase {
                Text("Next: \(next.label)\(next.duration.map { " · \(DurationFormat.clock($0))" } ?? "")")
                    .font(.app(.subheadline, .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }

            if !controller.movements.isEmpty {
                movementsList(display, color: color)
            }

            Spacer(minLength: 0)

            if kind.countsRounds || kind == .stopwatch {
                roundCounter(kind: kind, display: display, color: color)
            }

            controls(kind: kind, display: display)
        }
        .animation(Motion.smooth, value: display.phaseIndex)
        .animation(Motion.numeric, value: display.clockText)
        .animation(Motion.snappy, value: display.isPaused)
        .animation(Motion.lively, value: display.roundsCompleted)
    }

    private func movementsList(_ display: TimerDisplay, color: Color) -> some View {
        let config = controller.program.config
        let alternating = config.alternateMovements && controller.movements.count > 1
        let current = display.phase.kind == .work ? display.phase.workIndex % max(1, controller.movements.count) : -1
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(controller.movements.enumerated()), id: \.offset) { index, movement in
                let highlighted = alternating && index == current
                HStack {
                    Text(movement.name)
                        .font(.app(.subheadline, highlighted ? .bold : .medium))
                    Spacer()
                    if let detail = movement.detail {
                        Text(detail)
                            .font(.num(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(highlighted ? color.opacity(0.22) : .white.opacity(0.06))
                )
                .scaleEffect(highlighted ? 1.02 : 1)
            }
        }
    }

    private func roundCounter(kind: TimerKind, display: TimerDisplay, color: Color) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .stopwatch ? "Laps" : "Rounds")
                    .eyebrow()
                Text("\(display.roundsCompleted)")
                    .font(.num(size: 38, .regular))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(display.roundsCompleted)))
            }
            Button {
                controller.undoRound()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .glassCircle()
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .disabled(display.roundsCompleted == 0)
            .opacity(display.roundsCompleted == 0 ? 0.4 : 1)
            .accessibilityLabel("Undo round")
            Button {
                controller.markRound()
            } label: {
                Label(kind == .stopwatch ? "Lap" : "Round", systemImage: "plus")
                    .font(.app(.title3, .semibold))
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.opacity(0.18)))
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .disabled(display.phase.kind == .prepare)
            .accessibilityIdentifier("markRound")
        }
    }

    private func controls(kind: TimerKind, display: TimerDisplay) -> some View {
        HStack(spacing: 22) {
            circleButton("backward.fill", label: "Previous interval") { controller.back() }
            Button {
                controller.togglePause()
            } label: {
                Image(systemName: display.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Theme.night)
                    .frame(width: 82, height: 82)
                    .background(Circle().fill(Theme.ink))
            }
            .buttonStyle(PressableStyle(scale: 0.92))
            .accessibilityLabel(display.isPaused ? "Resume" : "Pause")
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
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .glassCircle()
                Text(label)
                    .font(.app(.caption2, .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel(label)
    }

    // MARK: Finished

    private var resultPanel: some View {
        let config = controller.program.config
        let result = controller.result()
        return ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 20)
                Text(result.summary(for: config))
                    .font(.num(size: 38, .regular))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                Text(config.summary)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)

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
                            Text(config.kind == .stopwatch ? "Laps" : "Round splits")
                                .eyebrow()
                            ForEach(Array(controller.laps.enumerated()), id: \.offset) { index, lap in
                                HStack {
                                    Text("\(index + 1)")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(DurationFormat.clock(lap))
                                }
                                .font(.num(.subheadline))
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
                    }
                    if let notes {
                        TextField("Notes", text: notes, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
                    }
                }

                Button(action: onSave) {
                    Text(saveTitle)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("saveTimerResult")
                Button("Discard", role: .destructive) { confirmDiscard = true }
                    .font(.app(.subheadline, .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)
        }
    }

    private func resultStepper(title: String, value: Binding<Int>, editable: Bool) -> some View {
        HStack {
            Text(title)
                .font(.app(.headline))
            Spacer()
            if editable {
                Button { value.wrappedValue -= 1 } label: {
                    Image(systemName: "minus")
                        .frame(width: 40, height: 40)
                        .glassCircle()
                }
            }
            Text("\(value.wrappedValue)")
                .font(.num(.title2, .regular))
                .contentTransition(.numericText(value: Double(value.wrappedValue)))
                .animation(Motion.numeric, value: value.wrappedValue)
                .frame(minWidth: 50)
            if editable {
                Button { value.wrappedValue += 1 } label: {
                    Image(systemName: "plus")
                        .frame(width: 40, height: 40)
                        .glassCircle()
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
        .buttonStyle(PressableStyle(scale: 0.9))
        .sensoryFeedback(.selection, trigger: value.wrappedValue)
    }

    // MARK: Text

    private func phaseTitle(_ display: TimerDisplay) -> String {
        switch display.phase.kind {
        case .prepare: return "Get Ready"
        case .rest: return display.phase.label == "Rest" ? "Rest" : display.phase.label
        case .setRest: return "Set Rest"
        case .work:
            let kind = controller.program.config.kind
            switch kind {
            case .custom: return display.phase.label
            case .emom: return "Work"
            case .deathBy: return "Round \(display.phase.round)"
            default: return kind == .tabata || kind == .intervals ? "Work" : kind.displayName
            }
        }
    }

    private func roundText(_ display: TimerDisplay) -> String? {
        let phase = display.phase
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

/// The ring, redrawn every frame from the run's wall-clock time so it sweeps
/// smoothly; nothing else on the timer screen redraws that often.
struct TimerRing: View {
    let controller: TimerController
    let color: Color

    var body: some View {
        let display = controller.display
        TimelineView(.animation(minimumInterval: AppEnvironment.isUITest ? 0.5 : nil, paused: display.isPaused || display.isFinished)) { context in
            let snapshot = controller.program.snapshot(for: controller.run, at: context.date)
            ProgressRing(progress: Self.progress(snapshot), color: color, lineWidth: 8, glows: true)
        }
    }

    /// Timed phases fill once; open-ended ones (stopwatch, For Time without a
    /// cap) sweep once a minute like a second hand.
    static func progress(_ snapshot: TimerSnapshot) -> Double {
        if snapshot.isFinished { return 1 }
        if snapshot.phase.duration == nil {
            return snapshot.phaseElapsed.truncatingRemainder(dividingBy: 60) / 60
        }
        return snapshot.phaseProgress
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
