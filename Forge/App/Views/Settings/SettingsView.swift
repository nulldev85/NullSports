import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let settings = app.settings
        Form {
            Section {
                NavigationLink {
                    BackupsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Backups & Export")
                            if let last = lastBackupDate {
                                Text("Last backup \(last.formatted(.relative(presentation: .named)))")
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                .accessibilityIdentifier("backupsLink")
                NavigationLink {
                    RecentlyDeletedView()
                } label: {
                    HStack {
                        Label("Recently Deleted", systemImage: "trash")
                        Spacer()
                        let count = app.history.deleted.count + app.routines.deletedRoutines.count
                        if count > 0 {
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    ArchivedExercisesView()
                } label: {
                    HStack {
                        Label("Archived Exercises", systemImage: "archivebox")
                        Spacer()
                        if !app.library.archivedCustoms.isEmpty {
                            Text("\(app.library.archivedCustoms.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Your Data")
            } footer: {
                Text("Everything is stored only on this iPhone. Nothing is uploaded unless you export it yourself.")
            }

            Section("Units") {
                Picker("Weight", selection: settings.binding(\.weightUnit)) {
                    ForEach(WeightUnit.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Distance", selection: settings.binding(\.distanceUnit)) {
                    ForEach(DistanceUnit.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Body Measurements", selection: settings.binding(\.lengthUnit)) {
                    ForEach(LengthUnit.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                Picker("Default Rest", selection: settings.binding(\.defaultRestSeconds)) {
                    Text("Off").tag(0)
                    ForEach(RestOptions.values, id: \.self) { Text(DurationFormat.compact(Double($0))).tag($0) }
                }
                Toggle("Start Rest Timer Automatically", isOn: settings.binding(\.autoStartRestTimer))
                Picker("Get-Ready for Timed Sets", selection: settings.binding(\.timedSetLeadIn)) {
                    Text("None").tag(0)
                    ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Timer Sounds", isOn: settings.binding(\.restTimerSound))
                Toggle("Timer Vibration", isOn: settings.binding(\.restTimerHaptics))
                Toggle("Notify When Timers End", isOn: settings.binding(\.restTimerNotifications))
                Toggle("Keep Screen On", isOn: settings.binding(\.keepScreenOn))
                Stepper("Weekly Goal: \(settings.value.weeklyGoal) workouts", value: settings.binding(\.weeklyGoal), in: 1...14)
            } header: {
                Text("Workouts")
            } footer: {
                Text("Timer sounds, vibration and notifications cover rest periods and timed sets (exercises tracked by time). Notifications alert you when one ends while Forge is in the background.")
            }

            Section {
                Toggle("Voice Announcements", isOn: settings.binding(\.timerVoice))
                Toggle("Announce Time Remaining", isOn: settings.binding(\.timerAnnounceRemaining))
                    .disabled(!settings.value.timerVoice)
                Toggle("Beeps", isOn: settings.binding(\.timerBeeps))
                Toggle("Vibration", isOn: settings.binding(\.timerHaptics))
                Toggle("Keep Running in Background", isOn: settings.binding(\.timerBackgroundAudio))
                Picker("Get-Ready Countdown", selection: settings.binding(\.defaultLeadIn)) {
                    Text("None").tag(0)
                    ForEach([3, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            } header: {
                Text("Interval Timers")
            } footer: {
                Text("With background running on, cues keep playing over your music while the phone is locked, for timed sets too.")
            }

            Section("Plates & Bar") {
                NavigationLink {
                    PlateInventoryView()
                } label: {
                    HStack {
                        Text("Bar and Plates")
                        Spacer()
                        Text("\(app.settings.units.weight(settings.value.barWeightInKilograms)) bar")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: settings.binding(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { Text($0.displayName).tag($0) }
                }
                AccentPicker(selection: settings.binding(\.accent))
            }

            Section("About") {
                LabeledContent("Version", value: DataSafetyStore.appVersion)
                LabeledContent("Workouts Logged", value: "\(app.history.summaries.count)")
                LabeledContent("Routines", value: "\(app.routines.routines.count)")
                LabeledContent("Exercises", value: "\(app.library.activeCount)")
                LabeledContent("Data Size", value: ByteCountFormatter.string(fromByteCount: Int64(app.database.fileSize), countStyle: .file))
                LabeledContent("Typefaces", value: "Manrope · Geist Mono (SIL OFL)")
            }
        }
        .canvasBackground()
        .navigationTitle("Settings")
        .stallContext("Settings")
        .onAppear { app.dataSafety.refresh() }
    }

    /// The newest snapshot or backup file.
    private var lastBackupDate: Date? {
        let safety = app.dataSafety
        return (safety.snapshots.map(\.date) + [safety.lastExportDate].compactMap { $0 }).max()
    }
}

struct AccentPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accent Color")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                ForEach(Theme.accents) { option in
                    let isSelected = Theme.canonicalID(selection) == option.id
                    Button {
                        // The whole app re-tints, so let the change glide.
                        withAnimation(Motion.gentle) { selection = option.id }
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.app(.caption, .semibold))
                                    .foregroundStyle(Theme.onAccent)
                                    .scaleEffect(isSelected ? 1 : 0.4)
                                    .opacity(isSelected ? 1 : 0)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(option.color.opacity(0.45), lineWidth: 2)
                                    .padding(-5)
                                    .opacity(isSelected ? 1 : 0)
                            )
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .accessibilityLabel(option.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

struct PlateInventoryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let settings = app.settings
        let isKilograms = settings.value.weightUnit == .kg
        Form {
            Section {
                HStack {
                    Text("Bar Weight")
                    Spacer()
                    DecimalField(placeholder: "0", value: Binding(
                        get: { isKilograms ? settings.value.barWeightKg : settings.value.barWeightLb },
                        set: { newValue in
                            settings.update { value in
                                if isKilograms {
                                    value.barWeightKg = newValue ?? 20
                                } else {
                                    value.barWeightLb = newValue ?? 45
                                }
                            }
                        }
                    ), alignment: .trailing)
                    .frame(width: 80)
                    Text(settings.value.weightUnit.symbol)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Used by the plate calculator and warm-up sets.")
            }
            Section {
                ForEach(Array(settings.value.plateInventory.enumerated()), id: \.offset) { index, plate in
                    Stepper(value: Binding(
                        get: { plate.pairs },
                        set: { pairs in
                            settings.update { value in
                                if isKilograms {
                                    if index < value.platesKg.count { value.platesKg[index].pairs = pairs }
                                } else {
                                    if index < value.platesLb.count { value.platesLb[index].pairs = pairs }
                                }
                            }
                        }
                    ), in: 0...20) {
                        HStack {
                            Text(app.settings.units.number(plate.weight) + " \(settings.value.weightUnit.symbol)")
                                .font(.app(.body, .semibold))
                            Spacer()
                            Text("\(plate.pairs) pair\(plate.pairs == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Available Plates")
            } footer: {
                Text("Pairs available (one plate per side).")
            }
            Section {
                Button("Reset to Standard Plates") {
                    settings.update { value in
                        if isKilograms {
                            value.platesKg = PlateStock.standardKilograms
                            value.barWeightKg = 20
                        } else {
                            value.platesLb = PlateStock.standardPounds
                            value.barWeightLb = 45
                        }
                    }
                }
            }
        }
        .canvasBackground()
        .navigationTitle("Bar & Plates")
    }
}

struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            if app.history.deleted.isEmpty, app.routines.deletedRoutines.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "trash", description: Text("Deleted workouts and routines stay here for 30 days."))
            }
            if !app.history.deleted.isEmpty {
                Section("Workouts") {
                    ForEach(app.history.deleted) { summary in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.name)
                                    .font(.app(.body, .semibold))
                                Text("\(summary.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(summary.setCount) sets")
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                                if let deletedAt = summary.deletedAt {
                                    Text(expiryText(deletedAt))
                                        .font(.app(.caption2))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Restore") { withAnimation(Motion.smooth) { app.history.restore(summary.id) } }
                                .buttonStyle(.bordered)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                withAnimation(Motion.smooth) { app.history.purge(summary.id) }
                            } label: {
                                Label("Delete Forever", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if !app.routines.deletedRoutines.isEmpty {
                Section("Routines") {
                    ForEach(app.routines.deletedRoutines) { routine in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(routine.name)
                                    .font(.app(.body, .semibold))
                                Text("\(routine.exerciseCount) exercises")
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                                if let deletedAt = routine.deletedAt {
                                    Text(expiryText(deletedAt))
                                        .font(.app(.caption2))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Restore") { withAnimation(Motion.smooth) { app.routines.restore(routine.id) } }
                                .buttonStyle(.bordered)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                withAnimation(Motion.smooth) { app.routines.purge(routine.id) }
                            } label: {
                                Label("Delete Forever", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .canvasBackground()
        .navigationTitle("Recently Deleted")
        .stallContext("Recently deleted")
    }

    private func expiryText(_ deletedAt: Date) -> String {
        let remaining = max(0, 30 - (Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0))
        return remaining == 1 ? "Deleted permanently in 1 day" : "Deleted permanently in \(remaining) days"
    }
}

struct ArchivedExercisesView: View {
    @Environment(AppModel.self) private var app
    @State private var deleting: Exercise?

    var body: some View {
        List {
            if app.library.archivedCustoms.isEmpty {
                ContentUnavailableView("No archived exercises", systemImage: "archivebox", description: Text("Custom exercises you archive are listed here with their history intact."))
            }
            ForEach(app.library.archivedCustoms) { exercise in
                HStack {
                    ExerciseRowLabel(exercise: exercise)
                    Spacer()
                    Button("Restore") { withAnimation(Motion.smooth) { app.library.unarchive(exercise.id) } }
                        .buttonStyle(.bordered)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        deleting = exercise
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .canvasBackground()
        .navigationTitle("Archived Exercises")
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")” permanently?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let exercise = deleting { withAnimation(Motion.smooth) { app.library.deletePermanently(exercise.id) } }
                deleting = nil
            }
        } message: {
            Text("Only possible if no workout or routine uses it. Otherwise it stays archived so your history stays intact.")
        }
    }
}
