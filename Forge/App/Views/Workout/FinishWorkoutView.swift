import SwiftUI

struct FinishWorkoutView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes = ""
    @State private var rating: Int?
    @State private var startedAt = Date()
    @State private var endedAt = Date()
    @State private var completeRemaining = false
    @State private var updateRoutine = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if let workout = app.session.workout {
                    summarySection(workout)
                    Section("Details") {
                        TextField("Workout name", text: $name)
                        TextField("How did it go?", text: $notes, axis: .vertical)
                            .lineLimit(2...6)
                        RatingPicker(rating: $rating)
                    }
                    Section("Time") {
                        DatePicker("Started", selection: $startedAt, in: ...endedAt)
                        DatePicker("Finished", selection: $endedAt, in: startedAt...)
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(DurationFormat.clock(max(0, endedAt.timeIntervalSince(startedAt))))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    if workout.incompleteSetCount > 0 {
                        Section {
                            Toggle("Log unchecked sets as done", isOn: $completeRemaining)
                        } footer: {
                            Text("\(workout.incompleteSetCount) \(workout.incompleteSetCount == 1 ? "set wasn't" : "sets weren't") checked off. Leave this off to drop them, or turn it on to log them using their entered values or targets.")
                        }
                    }
                    if let routineID = workout.routineID, let routine = app.routines.routine(routineID), app.session.routineDiffers() {
                        Section {
                            Toggle("Update “\(routine.name)”", isOn: $updateRoutine)
                        } footer: {
                            Text("Saves today's exercises, sets and weights as the routine's new targets.")
                        }
                    }
                }
            }
            .canvasBackground()
            .navigationTitle("Finish Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.bold)
                        .accessibilityIdentifier("saveFinishedWorkout")
                }
            }
            .onAppear(perform: load)
        }
    }

    private func summarySection(_ workout: Workout) -> some View {
        let units = app.settings.units
        return Section {
            HStack(spacing: 10) {
                StatTile(title: "Duration", value: DurationFormat.compact(max(0, endedAt.timeIntervalSince(startedAt))), symbol: "clock")
                StatTile(title: "Sets", value: "\(workout.completedWorkingSets.count)", symbol: "checkmark.circle")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            HStack(spacing: 10) {
                StatTile(title: "Volume", value: units.volume(workout.volume), symbol: "scalemass")
                StatTile(title: "Exercises", value: "\(workout.allExercises.count)", symbol: "dumbbell")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func load() {
        guard !loaded, let workout = app.session.workout else { return }
        loaded = true
        name = workout.name
        notes = workout.notes
        rating = workout.rating
        startedAt = workout.startedAt
        endedAt = Date()
    }

    private func save() {
        let options = WorkoutSession.FinishOptions(
            name: name,
            notes: notes,
            rating: rating,
            startedAt: startedAt,
            endedAt: max(endedAt, startedAt),
            completeRemaining: completeRemaining,
            updateRoutine: updateRoutine
        )
        dismiss()
        let session = app.session
        afterDelay(0.35) {
            session.finish(options)
        }
    }
}

struct RatingPicker: View {
    @Binding var rating: Int?

    var body: some View {
        HStack {
            Text("Rating")
            Spacer()
            ForEach(1...5, id: \.self) { value in
                Button {
                    withAnimation(Motion.snappy) {
                        rating = rating == value ? nil : value
                    }
                } label: {
                    Image(systemName: (rating ?? 0) >= value ? "star.fill" : "star")
                        .foregroundStyle((rating ?? 0) >= value ? Theme.record : Color.secondary)
                        .font(.app(.title3))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: rating == value)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) stars")
            }
        }
        .sensoryFeedback(.selection, trigger: rating)
    }
}

/// Shown right after finishing: the numbers and any new records.
struct WorkoutSummaryView: View {
    let summary: WorkoutSession.FinishedWorkout
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    var body: some View {
        let workout = summary.workout
        let units = app.settings.units
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        let tint = summary.records.isEmpty ? Color.accentColor : Theme.record
                        ZStack {
                            // A soft halo and one ripple ring as it lands.
                            Circle()
                                .fill(tint.opacity(0.14))
                                .frame(width: 118, height: 118)
                                .scaleEffect(appeared ? 1 : 0.5)
                            Circle()
                                .stroke(tint.opacity(appeared ? 0 : 0.6), lineWidth: 2)
                                .frame(width: 118, height: 118)
                                .scaleEffect(appeared ? 1.7 : 0.8)
                                .animation(.easeOut(duration: 1.1).delay(0.15), value: appeared)
                            Image(systemName: summary.records.isEmpty ? "checkmark.seal.fill" : "trophy.fill")
                                .font(.system(size: 60, weight: .bold))
                                .foregroundStyle(tint)
                                .symbolEffect(.bounce, value: appeared)
                                .scaleEffect(appeared ? 1 : 0.4)
                        }
                        .opacity(appeared ? 1 : 0)
                        .padding(.bottom, 6)
                        Text(summary.records.isEmpty ? "Workout complete" : "New personal records!")
                            .font(.app(.title2, .semibold))
                        Text(workout.name)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatTile(title: "Duration", value: DurationFormat.compact(workout.elapsed()), symbol: "clock")
                        StatTile(title: "Volume", value: units.volume(workout.volume), symbol: "scalemass")
                        StatTile(title: "Sets", value: "\(workout.completedWorkingSets.count)", symbol: "checkmark.circle")
                        StatTile(title: "Records", value: "\(summary.records.count)", symbol: "trophy", tint: Theme.record)
                    }
                    .entrance(appeared, delay: 0.12)

                    if !summary.records.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Records")
                            ForEach(summary.records) { record in
                                RecordRow(record: record, tracking: tracking(for: record))
                                    .cardStyle(padding: 12)
                            }
                        }
                        .entrance(appeared, delay: 0.22)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Exercises")
                        ForEach(workout.allExercises) { exercise in
                            HStack {
                                Text(exercise.name)
                                    .font(.app(.subheadline, .medium))
                                Spacer()
                                Text(setSummary(exercise))
                                    .font(.num(.subheadline))
                                    .foregroundStyle(.secondary)
                            }
                            .cardStyle(padding: 12)
                        }
                        ForEach(workout.blocks.filter { $0.timer != nil && $0.result != nil }) { block in
                            HStack {
                                Label(block.timer?.summary ?? "", systemImage: block.timer?.kind.symbolName ?? "timer")
                                    .font(.app(.subheadline, .medium))
                                Spacer()
                                Text(block.result.map { $0.summary(for: block.timer ?? .standard(.amrap)) } ?? "")
                                    .font(.num(.subheadline))
                                    .foregroundStyle(.secondary)
                            }
                            .cardStyle(padding: 12)
                        }
                    }
                    .entrance(appeared, delay: summary.records.isEmpty ? 0.22 : 0.32)
                }
                .padding(20)
            }
            .background(Theme.canvas)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("summaryDone")
                }
            }
            .onAppear {
                withAnimation(Motion.lively.delay(0.1)) {
                    appeared = true
                }
                if app.settings.value.timerHaptics {
                    app.cues.haptic(.success)
                }
            }
        }
    }

    private func tracking(for record: PersonalRecord) -> TrackingType {
        summary.workout.allExercises.first { $0.exerciseID == record.exerciseID }?.tracking ?? .weightReps
    }

    /// "3 sets · best 225 lb × 5", or the warm-up count if that's all.
    private func setSummary(_ exercise: WorkoutExercise) -> String {
        let working = exercise.sets.filter { $0.kind.isWorking }
        let best = working.max { lhs, rhs in
            if exercise.tracking.countsVolume { return lhs.volume < rhs.volume }
            if exercise.tracking.usesDistance { return (lhs.distance ?? 0) < (rhs.distance ?? 0) }
            if exercise.tracking.usesDuration { return (lhs.duration ?? 0) < (rhs.duration ?? 0) }
            return (lhs.reps ?? 0) < (rhs.reps ?? 0)
        }
        guard let best else {
            let warmups = exercise.sets.count
            if warmups == 0 { return "—" }
            return warmups == 1 ? "1 warm-up set" : "\(warmups) warm-up sets"
        }
        let count = working.count == 1 ? "1 set" : "\(working.count) sets"
        return "\(count) · best \(app.settings.units.setDescription(best, tracking: exercise.tracking))"
    }
}
