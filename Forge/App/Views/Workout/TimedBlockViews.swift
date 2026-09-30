import SwiftUI

/// A timed block (AMRAP, EMOM, Tabata…) inside the live workout.
struct TimedBlockSection: View, Equatable {
    let block: WorkoutBlock
    let index: Int
    let isRunning: Bool
    let run: () -> Void
    let logManually: () -> Void
    let editTimer: () -> Void
    let remove: () -> Void
    let clearResult: () -> Void
    @Environment(AppModel.self) private var app

    /// The actions always refer to this same block, so they don't count.
    nonisolated static func == (lhs: TimedBlockSection, rhs: TimedBlockSection) -> Bool {
        lhs.block == rhs.block && lhs.index == rhs.index && lhs.isRunning == rhs.isRunning
    }

    var body: some View {
        let config = block.timer ?? .standard(.amrap)
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconBadge(symbol: config.kind.symbolName, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.summary)
                            .font(.app(.headline))
                        Text(config.kind.tagline)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Edit Timer", systemImage: "slider.horizontal.3", action: editTimer)
                        Button("Log Result Manually", systemImage: "square.and.pencil", action: logManually)
                        if block.result != nil {
                            Button("Clear Result", systemImage: "arrow.uturn.backward", action: clearResult)
                        }
                        Divider()
                        Button("Remove Block", systemImage: "trash", role: .destructive, action: remove)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.app(.title3))
                    }
                }
            }
            .padding(.vertical, 6)
            .cardRow(.top)

            // Its own row, so the menu above can never trigger it.
            if let result = block.result {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.success)
                        .symbolEffect(.bounce, value: block.result != nil)
                    Text(result.summary(for: config))
                        .font(.app(.title3, .semibold))
                        .monospacedDigit()
                    Spacer()
                }
                .padding(12)
                .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .cardRow(block.exercises.isEmpty ? .bottom : [])
            } else {
                Button(action: run) {
                    Label(isRunning ? "Return to Timer" : "Start \(config.kind.displayName)", systemImage: isRunning ? "arrow.up.forward.app" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("startTimedBlock")
                .cardRow(block.exercises.isEmpty ? .bottom : [])
            }

            ForEach(Array(block.exercises.enumerated()), id: \.element.id) { position, entry in
                TimedMovementRow(entry: entry, hasResult: block.result != nil)
                    .cardRow(position == block.exercises.count - 1 ? .bottom : [])
            }
        } header: {
            BlockHeaderLabel(block: block, index: index)
        }
    }
}

struct TimedMovementRow: View {
    let entry: WorkoutExercise
    let hasResult: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.name)
                    .font(.app(.body, .semibold))
                Spacer()
                if hasResult {
                    Text("\(entry.sets.count) sets logged")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            if !hasResult {
                HStack(spacing: 8) {
                    Text("Per round")
                        .font(.app(.caption, .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    TrackingFields(
                        tracking: entry.tracking,
                        weight: targetBinding(\.weight),
                        reps: targetBinding(\.reps),
                        duration: targetBinding(\.duration),
                        distance: targetBinding(\.distance)
                    )
                }
            } else {
                Text(summary)
                    .font(.num(.subheadline))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let units = app.settings.units
        let totalReps = entry.sets.reduce(0) { $0 + ($1.reps ?? 0) }
        var parts: [String] = []
        if entry.tracking.usesReps, totalReps > 0 { parts.append("\(totalReps) reps total") }
        if let first = entry.sets.first {
            parts.append(units.setDescription(first, tracking: entry.tracking) + " each")
        }
        return parts.joined(separator: " · ")
    }

    /// Reads the value this row was drawn with, so the fields never observe
    /// the whole workout.
    private func targetBinding<T>(_ keyPath: WritableKeyPath<SetTarget, T?>) -> Binding<T?> {
        let session = app.session
        let current = entry.sets.first?.target?[keyPath: keyPath]
        return Binding(
            get: { current },
            set: { newValue in
                session.mutate { workout in
                    workout.updateExercise(entry.id) { exercise in
                        if exercise.sets.isEmpty { exercise.sets = [WorkoutSet(target: SetTarget())] }
                        var target = exercise.sets[0].target ?? SetTarget()
                        target[keyPath: keyPath] = newValue
                        exercise.sets[0].target = target
                    }
                }
            }
        )
    }
}

/// Record a timed block's outcome by hand (for when the timer wasn't used).
struct LogResultView: View {
    let blockID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rounds = 0
    @State private var extraReps = 0
    @State private var time: Double? = nil
    @State private var finished = true

    var body: some View {
        let config = app.session.workout?.block(blockID)?.timer ?? .standard(.amrap)
        NavigationStack {
            Form {
                Section {
                    NumberStepper(title: config.kind == .deathBy ? "Rounds completed" : "Rounds", value: $rounds, range: 0...500)
                    if config.kind == .amrap || config.kind == .forTime {
                        NumberStepper(title: "Extra reps", value: $extraReps, range: 0...999)
                    }
                    if config.kind == .forTime {
                        Toggle("Finished before the cap", isOn: $finished)
                        HStack {
                            Text("Time")
                            Spacer()
                            DurationField(placeholder: "12:34", seconds: $time, alignment: .trailing)
                                .frame(width: 100)
                        }
                    }
                } footer: {
                    Text("Each round is logged as sets using the per-round targets, so this work counts in your history and records.")
                }
            }
            .canvasBackground()
            .navigationTitle("Log \(config.kind.displayName)")
            .stallContext("Log result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let elapsed = time ?? TimerProgram(config: config).workDuration ?? 0
                        let result = BlockResult(
                            rounds: rounds,
                            extraReps: extraReps,
                            elapsed: elapsed,
                            finished: config.kind == .forTime ? finished : true
                        )
                        app.session.logResult(result, for: blockID)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            if let existing = app.session.workout?.block(blockID)?.result {
                rounds = existing.rounds
                extraReps = existing.extraReps
                time = existing.elapsed
                finished = existing.finished
            } else if [.emom, .tabata, .intervals].contains(config.kind) {
                rounds = TimerProgram(config: config).workPhaseCount
            }
        }
    }
}

/// Full-screen timer for a timed block inside a workout.
struct WorkoutTimerScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let controller = app.session.timedRun {
            TimerRunView(
                controller: controller,
                saveTitle: "Log Result",
                onSave: { app.session.completeTimedRun() },
                onMinimize: { app.session.isTimedRunPresented = false },
                onDiscard: { app.session.cancelTimedRun() }
            )
        } else {
            Theme.night
                .onAppear { app.session.isTimedRunPresented = false }
        }
    }
}
