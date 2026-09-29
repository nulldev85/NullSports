import SwiftUI

/// Identifies one input in the live workout so the keyboard's up/down
/// buttons can move between fields.
struct SetFieldID: Hashable {
    var setID: UUID
    var field: SetField
}

struct FieldFocus {
    var binding: FocusState<SetFieldID?>.Binding
    var id: SetFieldID
}

extension View {
    @ViewBuilder
    func externalFocus(_ focus: FieldFocus?) -> some View {
        if let focus {
            focused(focus.binding, equals: focus.id)
        } else {
            self
        }
    }
}

/// A text field bound to an optional number. The text the athlete types is
/// kept as-is while editing ("12." stays "12."); the bound value updates on
/// every valid keystroke so nothing is lost if the app closes mid-edit.
struct DecimalField: View {
    let placeholder: String
    @Binding var value: Double?
    var maxFractionDigits = 2
    var alignment: TextAlignment = .center
    var accessibilityName: String?
    var focus: FieldFocus?

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(alignment)
            .monospacedDigit()
            .focused($isFocused)
            .externalFocus(focus)
            .accessibilityLabel(accessibilityName ?? placeholder)
            .onAppear { text = Self.format(value, maxFractionDigits) }
            .onChange(of: value) { _, newValue in
                if isFocused, NumberFormatting.parseDecimal(text) == newValue { return }
                text = Self.format(newValue, maxFractionDigits)
            }
            .onChange(of: text) { _, newText in
                guard isFocused else { return }
                let parsed = NumberFormatting.parseDecimal(newText).map { max(0, $0) }
                if parsed != value { value = parsed }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { text = Self.format(value, maxFractionDigits) }
            }
    }

    static func format(_ value: Double?, _ digits: Int) -> String {
        guard let value else { return "" }
        return NumberFormatting.string(value, locale: .current, maxFractionDigits: digits, grouping: false)
    }
}

struct IntegerField: View {
    let placeholder: String
    @Binding var value: Int?
    var alignment: TextAlignment = .center
    var accessibilityName: String?
    var focus: FieldFocus?

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(alignment)
            .monospacedDigit()
            .focused($isFocused)
            .externalFocus(focus)
            .accessibilityLabel(accessibilityName ?? placeholder)
            .onAppear { text = value.map(String.init) ?? "" }
            .onChange(of: value) { _, newValue in
                if isFocused, Int(text) == newValue { return }
                text = newValue.map(String.init) ?? ""
            }
            .onChange(of: text) { _, newText in
                guard isFocused else { return }
                let digits = newText.filter(\.isNumber)
                if digits != newText { text = digits }
                let parsed = Int(digits.prefix(6))
                if parsed != value { value = parsed }
            }
    }
}

/// Accepts "90", "1:30" or "12.5" (seconds).
struct DurationField: View {
    let placeholder: String
    @Binding var seconds: Double?
    var alignment: TextAlignment = .center
    var accessibilityName: String?
    var focus: FieldFocus?

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(alignment)
            .monospacedDigit()
            .focused($isFocused)
            .externalFocus(focus)
            .accessibilityLabel(accessibilityName ?? placeholder)
            .onAppear { text = Self.format(seconds) }
            .onChange(of: seconds) { _, newValue in
                if isFocused, DurationFormat.parse(text) == newValue { return }
                text = Self.format(newValue)
            }
            .onChange(of: text) { _, newText in
                guard isFocused else { return }
                let parsed = DurationFormat.parse(newText)
                if parsed != seconds { seconds = parsed }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { text = Self.format(seconds) }
            }
    }

    static func format(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let hasFraction = abs(seconds - seconds.rounded()) > 0.001
        if hasFraction {
            if seconds < 60 { return String(format: "%.1f", seconds) }
            return DurationFormat.precise(seconds).replacingOccurrences(of: "s", with: "")
        }
        return DurationFormat.clock(seconds)
    }
}

/// A compact stepper-style picker for whole numbers (rounds, reps, sets).
struct NumberStepper: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...999
    var step = 1
    var suffix: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                value = max(range.lowerBound, value - step)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.bordered)
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Decrease \(title)")
            Text(suffix.map { "\(value) \($0)" } ?? "\(value)")
                .font(.app(.body, .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .animation(Motion.numeric, value: value)
                .frame(minWidth: 54)
            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.bordered)
            .disabled(value >= range.upperBound)
            .accessibilityLabel("Increase \(title)")
        }
        .sensoryFeedback(.selection, trigger: value)
    }
}

/// Minutes/seconds wheel for picking a duration.
struct DurationPicker: View {
    let title: String
    @Binding var seconds: Double
    var maxMinutes = 120
    var secondStep = 5
    var allowsZero = false
    var showsHeader = true

    var body: some View {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = Binding<Int>(
            get: { totalSeconds / 60 },
            set: { seconds = Double(normalized($0 * 60 + totalSeconds % 60)) }
        )
        let secs = Binding<Int>(
            get: { (totalSeconds % 60) / secondStep * secondStep },
            set: { seconds = Double(normalized((totalSeconds / 60) * 60 + $0)) }
        )
        VStack(alignment: .leading, spacing: 4) {
            if showsHeader {
                HStack {
                    Text(title)
                    Spacer()
                    Text(DurationFormat.clock(seconds))
                        .font(.app(.body, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                Picker("Minutes", selection: minutes) {
                    ForEach(0...maxMinutes, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
                Picker("Seconds", selection: secs) {
                    ForEach(Array(stride(from: 0, to: 60, by: secondStep)), id: \.self) { Text("\($0) sec").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .frame(height: 120)
        }
    }

    private func normalized(_ value: Int) -> Int {
        allowsZero ? max(0, value) : max(secondStep, value)
    }
}

/// A duration row that expands into wheels when tapped.
struct DurationRow: View {
    let title: String
    @Binding var seconds: Double
    var maxMinutes = 120
    var secondStep = 5
    var allowsZero = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.smooth) { expanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(seconds > 0 || allowsZero ? DurationFormat.clock(seconds) : "Off")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: seconds))
                        .animation(Motion.numeric, value: seconds)
                        .foregroundStyle(expanded ? Color.accentColor : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                DurationPicker(title: title, seconds: $seconds, maxMinutes: maxMinutes, secondStep: secondStep, allowsZero: allowsZero, showsHeader: false)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
