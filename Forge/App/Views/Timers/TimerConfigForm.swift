import SwiftUI

/// Settings for one timer format. Used by the Timers tab and by timed blocks
/// in routines and workouts.
struct TimerConfigForm: View {
    @Binding var config: TimerConfig
    var showsLeadIn = true

    var body: some View {
        switch config.kind {
        case .stopwatch:
            Section {
                Text("Counts up until you stop it. Tap Lap to record splits.")
                    .foregroundStyle(.secondary)
            }
        case .countdown:
            Section("Countdown") {
                DurationRow(title: "Duration", seconds: $config.duration, maxMinutes: 180, secondStep: 5)
            }
        case .forTime:
            Section {
                Toggle("Time Cap", isOn: Binding(
                    get: { config.duration > 0 },
                    set: { config.duration = $0 ? max(config.duration, 15 * 60) : 0 }
                ))
                if config.duration > 0 {
                    DurationRow(title: "Cap", seconds: $config.duration, maxMinutes: 120, secondStep: 15)
                }
                NumberStepper(title: "Rounds", value: $config.rounds, range: 0...100)
            } header: {
                Text("For Time")
            } footer: {
                Text("Set rounds to 0 for a single piece of work (a chipper). Tap Round while it runs to record splits.")
            }
        case .amrap:
            Section {
                DurationRow(title: "Duration", seconds: $config.duration, maxMinutes: 120, secondStep: 15)
            } header: {
                Text("AMRAP")
            } footer: {
                Text("Tap Round each time you finish a round; add leftover reps at the end.")
            }
        case .emom:
            Section {
                DurationRow(title: "Every", seconds: $config.interval, maxMinutes: 10, secondStep: 5)
                NumberStepper(title: "Rounds", value: $config.rounds, range: 1...200)
                LabeledContent("Total", value: DurationFormat.clock(config.interval * Double(config.rounds)))
            } header: {
                Text("Every Minute on the Minute")
            } footer: {
                Text("Change the interval for E2MOM, E3MOM and so on.")
            }
        case .tabata, .intervals:
            Section(config.kind == .tabata ? "Tabata" : "Intervals") {
                DurationRow(title: "Work", seconds: $config.work, maxMinutes: 30, secondStep: 5)
                DurationRow(title: "Rest", seconds: $config.rest, maxMinutes: 30, secondStep: 5, allowsZero: true)
                NumberStepper(title: "Rounds", value: $config.rounds, range: 1...100)
            }
            Section {
                NumberStepper(title: "Sets", value: $config.sets, range: 1...20)
                if config.sets > 1 {
                    DurationRow(title: "Rest Between Sets", seconds: $config.restBetweenSets, maxMinutes: 30, secondStep: 15, allowsZero: true)
                }
                Toggle("Skip Final Rest", isOn: $config.skipLastRest)
            } footer: {
                Text("Total \(totalText)")
                    .contentTransition(.numericText())
                    .animation(Motion.numeric, value: totalText)
            }
        case .custom:
            CustomSegmentsSection(config: $config)
            Section {
                NumberStepper(title: "Repeat", value: $config.sets, range: 1...50, suffix: "×")
                if config.sets > 1 {
                    DurationRow(title: "Rest Between Repeats", seconds: $config.restBetweenSets, maxMinutes: 30, secondStep: 15, allowsZero: true)
                }
                Toggle("Skip Final Rest", isOn: $config.skipLastRest)
            } footer: {
                Text("Total \(totalText)")
                    .contentTransition(.numericText())
                    .animation(Motion.numeric, value: totalText)
            }
        case .deathBy:
            Section {
                DurationRow(title: "Every", seconds: $config.interval, maxMinutes: 10, secondStep: 5)
                NumberStepper(title: "Start at", value: $config.startReps, range: 1...100, suffix: "reps")
                NumberStepper(title: "Add each round", value: $config.repIncrement, range: 1...20, suffix: "reps")
                NumberStepper(title: "Max rounds", value: $config.rounds, range: 1...200)
            } header: {
                Text("Death By")
            } footer: {
                Text("Keep going until you can't finish the reps inside the interval, then tap Stop.")
            }
        }
        if showsLeadIn {
            Section {
                Picker("Get-Ready Countdown", selection: Binding(
                    get: { Int(config.leadIn) },
                    set: { config.leadIn = Double($0) }
                )) {
                    Text("None").tag(0)
                    ForEach([3, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
        }
    }

    private var totalText: String {
        let program = TimerProgram(config: config)
        return program.workDuration.map { DurationFormat.clock($0) } ?? "open-ended"
    }
}

struct CustomSegmentsSection: View {
    @Binding var config: TimerConfig

    var body: some View {
        Section {
            ForEach($config.segments) { $segment in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Name", text: $segment.name)
                            .font(.app(.body, .semibold))
                        Picker("Kind", selection: $segment.kind) {
                            Text("Work").tag(SegmentKind.work)
                            Text("Rest").tag(SegmentKind.rest)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                    }
                    DurationRow(title: "Length", seconds: $segment.duration, maxMinutes: 60, secondStep: 5)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                config.segments.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                config.segments.move(fromOffsets: source, toOffset: destination)
            }
            Button {
                let isRest = config.segments.last?.kind == .work
                config.segments.append(IntervalSegment(name: isRest ? "Rest" : "Work", duration: isRest ? 15 : 30, kind: isRest ? .rest : .work))
            } label: {
                Label("Add Interval", systemImage: "plus")
            }
            .buttonStyle(.row)
        } header: {
            Text("Sequence")
        } footer: {
            Text("Name each interval (e.g. Sprint, Jog, Walk) and it will be announced when it starts. Swipe to delete.")
        }
    }
}
