import SwiftUI

struct PlateCalculatorView: View {
    @Environment(AppModel.self) private var app
    @State private var target: Double?

    var body: some View {
        let settings = app.settings.value
        let unit = settings.weightUnit
        let bar = unit == .kg ? settings.barWeightKg : settings.barWeightLb
        let load = target.map { PlateCalculator.load(target: $0, bar: bar, inventory: settings.plateInventory) }
        Form {
            Section {
                HStack {
                    Text("Target")
                    Spacer()
                    DecimalField(placeholder: unit == .kg ? "100" : "225", value: $target, alignment: .trailing)
                        .font(.app(.title3, .semibold))
                        .frame(width: 120)
                    Text(unit.symbol)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Bar", value: "\(app.settings.units.number(bar)) \(unit.symbol)")
            }
            if let load {
                Section {
                    BarbellDiagram(plates: load.perSide, unit: unit)
                        .frame(height: 140)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
                    if load.perSide.isEmpty {
                        Text("Just the bar.")
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Each side", value: load.perSide.map { app.settings.units.number($0) }.joined(separator: " + "))
                    }
                    LabeledContent("Total", value: "\(app.settings.units.number(load.achieved)) \(unit.symbol)")
                    if !load.isExact {
                        Label("\(app.settings.units.number(load.remainder)) \(unit.symbol) short with your plates", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                } header: {
                    Text("Load")
                }
            }
            Section {
                NavigationLink("Edit Bar & Plates") {
                    PlateInventoryView()
                }
                .buttonStyle(.navigationRow)
            }
        }
        .canvasBackground()
        .navigationTitle("Plate Calculator")
        .stallContext("Plate calculator")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { dismissKeyboard() }
            }
        }
        .onAppear {
            // Start with a common load so the diagram shows right away.
            if target == nil { target = unit == .kg ? 100 : 225 }
        }
    }
}

/// Plates drawn on one side of a bar, heaviest nearest the collar.
struct BarbellDiagram: View {
    let plates: [Double]
    let unit: WeightUnit

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            HStack(spacing: 3) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 40, height: 10)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary)
                    .frame(width: 10, height: 28)
                ForEach(Array(plates.enumerated()), id: \.offset) { _, plate in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color(for: plate))
                        .frame(width: width(for: plate), height: max(26, height * scale(for: plate)))
                        .overlay(
                            Text(label(plate))
                                .font(.num(size: 9, .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .rotationEffect(.degrees(-90))
                                .fixedSize()
                        )
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // Plates slide on and off as the target changes.
            .animation(Motion.smooth, value: plates)
        }
    }

    private func kilograms(_ plate: Double) -> Double {
        unit.toKilograms(plate)
    }

    private func scale(for plate: Double) -> CGFloat {
        let kg = kilograms(plate)
        switch kg {
        case 15...: return 1.0
        case 10..<15: return 0.85
        case 5..<10: return 0.62
        case 2.5..<5: return 0.48
        default: return 0.36
        }
    }

    private func width(for plate: Double) -> CGFloat {
        kilograms(plate) >= 10 ? 18 : 12
    }

    private func color(for plate: Double) -> Color {
        let kg = kilograms(plate)
        switch kg {
        // The usual competition colors, in the app's muted palette.
        case 24...: return Theme.rose
        case 19..<24: return Theme.mist
        case 14..<19: return Theme.sand
        case 9..<14: return Theme.sage
        case 4..<9: return Theme.slate
        default: return Theme.slate.opacity(0.7)
        }
    }

    private func label(_ plate: Double) -> String {
        plate == plate.rounded() ? "\(Int(plate))" : String(format: "%.2g", plate)
    }
}

struct OneRepMaxView: View {
    @Environment(AppModel.self) private var app
    @State private var weight: Double?
    @State private var reps: Int? = 5

    var body: some View {
        let unit = app.settings.value.weightUnit
        let estimate: Double? = {
            guard let weight, let reps, reps > 0, reps <= 30 else { return nil }
            return reps == 1 ? weight : OneRepMax.epley(weight: weight, reps: reps)
        }()
        Form {
            Section {
                HStack {
                    Text("Weight")
                    Spacer()
                    DecimalField(placeholder: "0", value: $weight, alignment: .trailing)
                        .frame(width: 100)
                    Text(unit.symbol)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Reps")
                    Spacer()
                    IntegerField(placeholder: "5", value: $reps, alignment: .trailing)
                        .frame(width: 100)
                }
            } footer: {
                Text("Estimates are most accurate between 1 and 10 reps.")
            }
            if let estimate {
                Section {
                    HStack {
                        Text("Estimated 1RM")
                            .font(.app(.headline))
                        Spacer()
                        Text("\(app.settings.units.number(estimate, maxFractionDigits: 1)) \(unit.symbol)")
                            .font(.num(.title2, .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Section("Training Loads") {
                    ForEach(OneRepMax.table(oneRepMax: estimate), id: \.percent) { row in
                        HStack {
                            Text("\(row.percent)%")
                                .frame(width: 50, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text("\(app.settings.units.number(row.weight, maxFractionDigits: 1)) \(unit.symbol)")
                                .font(.num(.body, .medium))
                            Spacer()
                            Text("≈ \(row.reps) rep\(row.reps == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .canvasBackground()
        .navigationTitle("One-Rep Max")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { dismissKeyboard() }
            }
        }
    }
}

struct WarmupCalculatorView: View {
    @Environment(AppModel.self) private var app
    @State private var working: Double?

    var body: some View {
        let settings = app.settings.value
        let unit = settings.weightUnit
        let bar = unit == .kg ? settings.barWeightKg : settings.barWeightLb
        let steps = working.map { WarmupCalculator.steps(workingWeight: $0, bar: bar, increment: unit.standardIncrement) } ?? []
        Form {
            Section {
                HStack {
                    Text("Working Weight")
                    Spacer()
                    DecimalField(placeholder: "0", value: $working, alignment: .trailing)
                        .frame(width: 100)
                    Text(unit.symbol)
                        .foregroundStyle(.secondary)
                }
            }
            if !steps.isEmpty {
                Section("Warm-up Sets") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack {
                            SetKindBadge(kind: .warmup, number: index + 1)
                            Text("\(app.settings.units.number(step.weight)) \(unit.symbol)")
                                .font(.num(.body, .medium))
                            Spacer()
                            Text("× \(step.reps)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        SetKindBadge(kind: .normal, number: 1)
                        Text("\(app.settings.units.number(working ?? 0)) \(unit.symbol)")
                            .font(.num(.body, .semibold))
                        Spacer()
                        Text("Working sets")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if working != nil {
                Section {
                    Text("That's light enough to start working sets straight away.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("In a workout, use an exercise's menu › Add Warm-up Sets to insert these automatically.")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .canvasBackground()
        .navigationTitle("Warm-up Sets")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { dismissKeyboard() }
            }
        }
    }
}
