import SwiftUI

enum TargetFormatter {
    /// "100 kg × 5", "× 8–12", "1:00", "5 km", "—".
    static func describe(_ target: SetTarget?, tracking: TrackingType, units: UnitPreferences) -> String {
        guard let target, !target.isEmpty else { return "—" }
        var parts: [String] = []
        if tracking.usesWeight, let weight = target.weight {
            switch tracking {
            case .weightedBodyweight: parts.append("+" + units.weight(weight))
            case .assistedBodyweight: parts.append("−" + units.weight(weight))
            default: parts.append(units.weight(weight))
            }
        }
        if tracking.usesReps, let reps = target.repsText {
            parts.append(parts.isEmpty ? "\(reps) reps" : "× \(reps)")
        }
        if tracking.usesDistance, let distance = target.distance {
            parts.append(units.distance(distance, short: tracking.usesShortDistance))
        }
        if tracking.usesDuration, let duration = target.duration {
            parts.append(DurationFormat.precise(duration))
        }
        if let rpe = target.rpe {
            parts.append("@\(NumberFormatting.string(rpe, locale: .current, maxFractionDigits: 1, grouping: false))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    static func unitLabel(_ field: SetField, tracking: TrackingType, units: UnitPreferences) -> String {
        switch field {
        case .weight:
            switch tracking {
            case .weightedBodyweight: return "+\(units.weight.symbol)"
            case .assistedBodyweight: return "−\(units.weight.symbol)"
            default: return units.weight.symbol
            }
        case .reps: return "Reps"
        case .duration: return "Time"
        case .distance: return units.distance.symbol(short: tracking.usesShortDistance)
        }
    }
}

/// Fixed column widths so headers and rows line up.
enum SetColumn {
    static let badge: CGFloat = 34
    static let check: CGFloat = 40

    static func width(for field: SetField) -> CGFloat {
        switch field {
        case .weight: return 70
        case .reps: return 58
        case .duration: return 70
        case .distance: return 70
        }
    }
}

/// A rounded input well for numbers in set rows.
struct FieldWell<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.body.weight(.semibold))
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? Color.green.opacity(0.14) : Color(.tertiarySystemFill))
            )
    }
}

/// The measurement inputs for one set, according to how the exercise is
/// tracked. Values are stored metric; fields show the athlete's units.
struct TrackingFields: View {
    let tracking: TrackingType
    @Binding var weight: Double?
    @Binding var reps: Int?
    @Binding var duration: Double?
    @Binding var distance: Double?
    var placeholder: SetTarget?
    var completed = false
    /// Routine targets allow "8-12" style rep ranges.
    var repsMax: Binding<Int?>?
    @Environment(AppModel.self) private var app

    var body: some View {
        ForEach(tracking.fields, id: \.self) { field in
            FieldWell(highlighted: completed) {
                fieldView(field)
            }
            .frame(width: SetColumn.width(for: field))
        }
    }

    @ViewBuilder
    private func fieldView(_ field: SetField) -> some View {
        let units = app.settings.units
        switch field {
        case .weight:
            DecimalField(
                placeholder: placeholder?.weight.map { units.number(units.weight.fromKilograms($0)) } ?? "0",
                value: app.settings.weightBinding($weight),
                accessibilityName: "Weight"
            )
        case .reps:
            if let repsMax {
                RepsRangeField(reps: $reps, repsMax: repsMax, placeholder: placeholder?.repsText ?? "0")
            } else {
                IntegerField(placeholder: placeholder?.repsText ?? "0", value: $reps, accessibilityName: "Reps")
            }
        case .duration:
            DurationField(placeholder: placeholder?.duration.map { DurationFormat.clock($0) } ?? "0:00", seconds: $duration, accessibilityName: "Time")
        case .distance:
            DecimalField(
                placeholder: placeholder?.distance.map { units.number(units.distance.fromMeters($0, short: tracking.usesShortDistance)) } ?? "0",
                value: app.settings.distanceBinding($distance, short: tracking.usesShortDistance),
                accessibilityName: "Distance"
            )
        }
    }
}

/// Accepts "8" or a range like "8-12".
struct RepsRangeField: View {
    @Binding var reps: Int?
    @Binding var repsMax: Int?
    var placeholder = "0"

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .focused($isFocused)
            .accessibilityLabel("Reps")
            .onAppear { text = Self.format(reps, repsMax) }
            .onChange(of: text) { _, newText in
                guard isFocused else { return }
                let parsed = Self.parse(newText)
                reps = parsed.0
                repsMax = parsed.1
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { text = Self.format(reps, repsMax) }
            }
            .onChange(of: reps) { _, _ in
                if !isFocused { text = Self.format(reps, repsMax) }
            }
    }

    static func format(_ low: Int?, _ high: Int?) -> String {
        guard let low else { return "" }
        if let high, high > low { return "\(low)-\(high)" }
        return "\(low)"
    }

    static func parse(_ text: String) -> (Int?, Int?) {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" || $0 == " " })
            .map { String($0).filter(\.isNumber) }
            .filter { !$0.isEmpty }
        let low = parts.first.flatMap { Int($0.prefix(4)) }
        let high = parts.count > 1 ? Int(parts[1].prefix(4)) : nil
        if let low, let high, high > low { return (low, high) }
        return (low, nil)
    }
}

/// Column captions above set rows.
struct SetColumnsHeader: View {
    let tracking: TrackingType
    var showsPrevious = false
    var showsCheck = false
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Text("SET")
                .frame(width: SetColumn.badge)
            if showsPrevious {
                Text("PREVIOUS")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            ForEach(tracking.fields, id: \.self) { field in
                Text(TargetFormatter.unitLabel(field, tracking: tracking, units: app.settings.units).uppercased())
                    .frame(width: SetColumn.width(for: field))
            }
            if showsCheck {
                Image(systemName: "checkmark")
                    .frame(width: SetColumn.check)
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Badge that opens a menu to change the set type.
struct SetKindMenu: View {
    let kind: SetKind
    let number: Int
    var completed = false
    let onChange: (SetKind) -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        Menu {
            Picker("Set Type", selection: Binding(get: { kind }, set: onChange)) {
                ForEach(SetKind.allCases) { option in
                    Label(option.displayName, systemImage: symbol(for: option)).tag(option)
                }
            }
            if let onDelete {
                Divider()
                Button("Delete Set", systemImage: "trash", role: .destructive, action: onDelete)
            }
        } label: {
            SetKindBadge(kind: kind, number: number, completed: completed)
        }
        .frame(width: SetColumn.badge)
    }

    private func symbol(for kind: SetKind) -> String {
        switch kind {
        case .normal: return "number"
        case .warmup: return "flame"
        case .drop: return "arrow.down.right"
        case .failure: return "bolt.fill"
        }
    }
}

extension Array where Element == WorkoutSet {
    /// Display numbers: working sets count 1, 2, 3…; special kinds show letters.
    func workingNumber(at index: Int) -> Int {
        var number = 0
        for position in 0...index where self[position].kind != .warmup {
            number += 1
        }
        return Swift.max(number, 1)
    }
}

extension Array where Element == RoutineSet {
    func workingNumber(at index: Int) -> Int {
        var number = 0
        for position in 0...index where self[position].kind != .warmup {
            number += 1
        }
        return Swift.max(number, 1)
    }
}
