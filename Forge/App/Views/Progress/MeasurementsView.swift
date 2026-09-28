import Charts
import SwiftUI

struct MeasurementsView: View {
    @Environment(AppModel.self) private var app
    @State private var adding: MeasurementKind?

    var body: some View {
        let tracked = app.measurements.trackedKinds
        let untracked = MeasurementKind.allCases.filter { !tracked.contains($0) }
        List {
            if !tracked.isEmpty {
                Section("Tracking") {
                    ForEach(tracked) { kind in
                        NavigationLink {
                            MeasurementDetailView(kind: kind)
                        } label: {
                            MeasurementRow(kind: kind)
                        }
                    }
                }
            }
            Section(tracked.isEmpty ? "Start tracking" : "More") {
                ForEach(untracked) { kind in
                    Button {
                        adding = kind
                    } label: {
                        HStack {
                            Label(kind.displayName, systemImage: kind.symbolName)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Body")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(MeasurementKind.allCases) { kind in
                        Button(kind.displayName, systemImage: kind.symbolName) { adding = kind }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $adding) { kind in
            MeasurementEntryView(kind: kind, existing: nil)
                .environment(app)
        }
    }
}

struct MeasurementRow: View {
    let kind: MeasurementKind
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack {
            Label(kind.displayName, systemImage: kind.symbolName)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let latest = app.measurements.latest(kind) {
                    Text(app.settings.units.measurement(latest.value, kind: kind))
                        .font(.body.weight(.semibold).monospacedDigit())
                    if let change = app.measurements.change(kind), abs(change) > 0.0001 {
                        Text(changeText(change))
                            .font(.caption)
                            .foregroundStyle(changeColor(change))
                    }
                }
            }
        }
    }

    private func changeText(_ change: Double) -> String {
        let magnitude = app.settings.units.measurement(abs(change), kind: kind)
        return (change > 0 ? "+" : "−") + magnitude
    }

    private func changeColor(_ change: Double) -> Color {
        guard let lowerIsBetter = kind.lowerIsBetter else { return .secondary }
        let improved = lowerIsBetter ? change < 0 : change > 0
        return improved ? .green : .orange
    }
}

struct MeasurementDetailView: View {
    let kind: MeasurementKind
    @Environment(AppModel.self) private var app
    @State private var adding = false
    @State private var editing: BodyMeasurement?

    var body: some View {
        let entries = app.measurements.entries(kind)
        let units = app.settings.units
        List {
            if entries.count > 1 {
                Section {
                    Chart(entries) { entry in
                        LineMark(x: .value("Date", entry.measuredAt), y: .value(kind.displayName, units.displayMeasurement(entry.value, kind: kind)))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.accentColor)
                        PointMark(x: .value("Date", entry.measuredAt), y: .value(kind.displayName, units.displayMeasurement(entry.value, kind: kind)))
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(24)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 200)
                    .padding(.vertical, 8)
                }
            }
            Section("Entries") {
                if entries.isEmpty {
                    Text("No entries yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries.reversed()) { entry in
                    Button {
                        editing = entry
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.measuredAt.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(.primary)
                                if !entry.note.isEmpty {
                                    Text(entry.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(units.measurement(entry.value, kind: kind))
                                .font(.body.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            app.measurements.delete(entry.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(kind.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $adding) {
            MeasurementEntryView(kind: kind, existing: nil)
                .environment(app)
        }
        .sheet(item: $editing) { entry in
            MeasurementEntryView(kind: kind, existing: entry)
                .environment(app)
        }
    }
}

struct MeasurementEntryView: View {
    let kind: MeasurementKind
    let existing: BodyMeasurement?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double?
    @State private var date = Date()
    @State private var note = ""

    var body: some View {
        let units = app.settings.units
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(kind.displayName)
                        Spacer()
                        DecimalField(placeholder: "0", value: $value, alignment: .trailing)
                            .frame(width: 100)
                        Text(units.measurementUnitSymbol(kind))
                            .foregroundStyle(.secondary)
                    }
                    DatePicker("Date", selection: $date, in: ...Date())
                    TextField("Note (optional)", text: $note)
                }
            }
            .navigationTitle(existing == nil ? "Add \(kind.displayName)" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value else { return }
                        var entry = existing ?? BodyMeasurement(kind: kind, value: 0)
                        entry.value = units.storedMeasurement(value, kind: kind)
                        entry.measuredAt = date
                        entry.note = note
                        app.measurements.save(entry)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(value == nil)
                }
            }
            .onAppear {
                if let existing {
                    value = SettingsStore.clean(units.displayMeasurement(existing.value, kind: kind))
                    date = existing.measuredAt
                    note = existing.note
                } else if let latest = app.measurements.latest(kind) {
                    value = SettingsStore.clean(units.displayMeasurement(latest.value, kind: kind))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
