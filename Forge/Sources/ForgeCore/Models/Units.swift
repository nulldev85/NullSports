import Foundation

// All values are stored in metric (kg, m, cm, s). These types convert at the
// edges, for display and input only.

public enum WeightUnit: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case kg
    case lb

    public static var fallback: WeightUnit { .kg }
    public static let kilogramsPerPound = 0.45359237
    public var id: String { rawValue }

    public var symbol: String { rawValue }

    public var displayName: String {
        switch self {
        case .kg: return "Kilograms (kg)"
        case .lb: return "Pounds (lb)"
        }
    }

    public func fromKilograms(_ kilograms: Double) -> Double {
        switch self {
        case .kg: return kilograms
        case .lb: return kilograms / Self.kilogramsPerPound
        }
    }

    public func toKilograms(_ value: Double) -> Double {
        switch self {
        case .kg: return value
        case .lb: return value * Self.kilogramsPerPound
        }
    }

    /// Typical smallest jump on a loaded bar.
    public var standardIncrement: Double {
        switch self {
        case .kg: return 2.5
        case .lb: return 5
        }
    }
}

public enum DistanceUnit: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case kilometers = "km"
    case miles = "mi"

    public static var fallback: DistanceUnit { .kilometers }
    public static let metersPerMile = 1609.344
    public static let metersPerYard = 0.9144
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kilometers: return "Kilometers (km)"
        case .miles: return "Miles (mi)"
        }
    }

    public var longSymbol: String {
        switch self {
        case .kilometers: return "km"
        case .miles: return "mi"
        }
    }

    public var shortSymbol: String {
        switch self {
        case .kilometers: return "m"
        case .miles: return "yd"
        }
    }

    public func symbol(short: Bool) -> String { short ? shortSymbol : longSymbol }

    public func fromMeters(_ meters: Double, short: Bool) -> Double {
        switch (self, short) {
        case (.kilometers, false): return meters / 1000
        case (.kilometers, true): return meters
        case (.miles, false): return meters / Self.metersPerMile
        case (.miles, true): return meters / Self.metersPerYard
        }
    }

    public func toMeters(_ value: Double, short: Bool) -> Double {
        switch (self, short) {
        case (.kilometers, false): return value * 1000
        case (.kilometers, true): return value
        case (.miles, false): return value * Self.metersPerMile
        case (.miles, true): return value * Self.metersPerYard
        }
    }
}

public enum LengthUnit: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case centimeters = "cm"
    case inches = "in"

    public static var fallback: LengthUnit { .centimeters }
    public static let centimetersPerInch = 2.54
    public var id: String { rawValue }

    public var symbol: String { rawValue }

    public var displayName: String {
        switch self {
        case .centimeters: return "Centimeters (cm)"
        case .inches: return "Inches (in)"
        }
    }

    public func fromCentimeters(_ value: Double) -> Double {
        self == .centimeters ? value : value / Self.centimetersPerInch
    }

    public func toCentimeters(_ value: Double) -> Double {
        self == .centimeters ? value : value * Self.centimetersPerInch
    }
}

/// Converts and formats stored values for display according to the user's
/// unit preferences.
public struct UnitPreferences: Hashable, Sendable {
    public var weight: WeightUnit
    public var distance: DistanceUnit
    public var length: LengthUnit
    public var locale: Locale

    public init(weight: WeightUnit = .kg, distance: DistanceUnit = .kilometers, length: LengthUnit = .centimeters, locale: Locale = .current) {
        self.weight = weight
        self.distance = distance
        self.length = length
        self.locale = locale
    }

    public func number(_ value: Double, maxFractionDigits: Int = 2) -> String {
        NumberFormatting.string(value, locale: locale, maxFractionDigits: maxFractionDigits, grouping: abs(value) >= 10_000)
    }

    public func weightValue(_ kilograms: Double) -> Double {
        weight.fromKilograms(kilograms)
    }

    /// "102.5 kg"
    public func weight(_ kilograms: Double, includeUnit: Bool = true) -> String {
        let text = number(weight.fromKilograms(kilograms))
        return includeUnit ? "\(text) \(weight.symbol)" : text
    }

    /// Large totals such as volume: "12,340 kg" or "1.2M lb".
    public func volume(_ kilograms: Double) -> String {
        let value = weight.fromKilograms(kilograms)
        if value >= 1_000_000 {
            return "\(number(value / 1_000_000, maxFractionDigits: 1))M \(weight.symbol)"
        }
        let text = NumberFormatting.string(value.rounded(), locale: locale, maxFractionDigits: 0, grouping: true)
        return "\(text) \(weight.symbol)"
    }

    public func distanceValue(_ meters: Double, short: Bool) -> Double {
        distance.fromMeters(meters, short: short)
    }

    /// "5.2 km", "400 m", "3.1 mi".
    public func distance(_ meters: Double, short: Bool, includeUnit: Bool = true) -> String {
        let text = number(distance.fromMeters(meters, short: short), maxFractionDigits: short ? 1 : 2)
        return includeUnit ? "\(text) \(distance.symbol(short: short))" : text
    }

    public func length(_ centimeters: Double, includeUnit: Bool = true) -> String {
        let text = number(length.fromCentimeters(centimeters), maxFractionDigits: 1)
        return includeUnit ? "\(text) \(length.symbol)" : text
    }

    /// Pace for distance-based work: "5:12 /km".
    public func pace(meters: Double, seconds: Double) -> String? {
        guard meters > 0, seconds > 0 else { return nil }
        let perUnit = seconds / distance.fromMeters(meters, short: false)
        guard perUnit.isFinite, perUnit < 24 * 3600 else { return nil }
        return "\(DurationFormat.clock(perUnit)) /\(distance.longSymbol)"
    }

    public func measurement(_ value: Double, kind: MeasurementKind) -> String {
        switch kind.dimension {
        case .mass: return weight(value)
        case .length: return length(value)
        case .percent: return "\(number(value, maxFractionDigits: 1))%"
        case .beatsPerMinute: return "\(number(value, maxFractionDigits: 0)) bpm"
        case .hours: return "\(number(value, maxFractionDigits: 1)) h"
        case .kilocalories: return "\(number(value, maxFractionDigits: 0)) kcal"
        }
    }

    public func measurementUnitSymbol(_ kind: MeasurementKind) -> String {
        switch kind.dimension {
        case .mass: return weight.symbol
        case .length: return length.symbol
        case .percent: return "%"
        case .beatsPerMinute: return "bpm"
        case .hours: return "h"
        case .kilocalories: return "kcal"
        }
    }

    /// Converts a measurement to the unit shown on screen.
    public func displayMeasurement(_ value: Double, kind: MeasurementKind) -> Double {
        switch kind.dimension {
        case .mass: return weight.fromKilograms(value)
        case .length: return length.fromCentimeters(value)
        default: return value
        }
    }

    /// Converts user input back to the canonical unit.
    public func storedMeasurement(_ value: Double, kind: MeasurementKind) -> Double {
        switch kind.dimension {
        case .mass: return weight.toKilograms(value)
        case .length: return length.toCentimeters(value)
        default: return value
        }
    }

    /// Compact set description: "80 kg × 8", "12 reps", "+20 kg × 6",
    /// "1:30", "5 km in 25:00".
    public func setDescription(_ set: WorkoutSet, tracking: TrackingType) -> String {
        setDescription(weight: set.weight, reps: set.reps, duration: set.duration, distance: set.distance, tracking: tracking)
    }

    public func setDescription(weight weightKg: Double?, reps: Int?, duration: Double?, distance meters: Double?, tracking: TrackingType) -> String {
        switch tracking {
        case .weightReps:
            let w = weightKg.map { weight($0) } ?? "—"
            return "\(w) × \(reps.map(String.init) ?? "—")"
        case .weightedBodyweight:
            let w = weightKg.map { "+" + weight($0) } ?? "BW"
            return "\(w) × \(reps.map(String.init) ?? "—")"
        case .assistedBodyweight:
            let w = weightKg.map { "−" + weight($0) } ?? "BW"
            return "\(w) × \(reps.map(String.init) ?? "—")"
        case .reps:
            return reps.map { "\($0) reps" } ?? "—"
        case .duration:
            return duration.map { DurationFormat.precise($0) } ?? "—"
        case .weightDuration:
            let w = weightKg.map { weight($0) } ?? "—"
            return "\(w) · \(duration.map { DurationFormat.precise($0) } ?? "—")"
        case .distanceDuration, .shortDistance:
            let d = meters.map { distance($0, short: tracking.usesShortDistance) } ?? "—"
            if let duration { return "\(d) in \(DurationFormat.precise(duration))" }
            return d
        case .weightDistance:
            let w = weightKg.map { weight($0) } ?? "—"
            return "\(w) · \(meters.map { distance($0, short: true) } ?? "—")"
        }
    }
}

/// NumberFormatter is expensive to create; list rows format a lot of
/// numbers, so formatters are cached per configuration.
public enum NumberFormatting {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NumberFormatter] = [:]

    public static func string(_ value: Double, locale: Locale, maxFractionDigits: Int, grouping: Bool) -> String {
        let key = "\(locale.identifier)|\(maxFractionDigits)|\(grouping)"
        lock.lock()
        defer { lock.unlock() }
        let formatter: NumberFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = grouping
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = maxFractionDigits
            cache[key] = formatter
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Parses user input, accepting either "." or "," as the decimal mark
    /// regardless of locale (hardware keyboards and habits vary).
    public static func parseDecimal(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed.removeAll { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" || $0 == "'" }
        guard !trimmed.isEmpty else { return nil }
        let commas = trimmed.filter { $0 == "," }.count
        let dots = trimmed.filter { $0 == "." }.count
        if commas > 0, dots > 0 {
            // Whichever separator comes last is the decimal mark.
            let lastComma = trimmed.lastIndex(of: ",")!
            let lastDot = trimmed.lastIndex(of: ".")!
            if lastComma > lastDot {
                trimmed.removeAll { $0 == "." }
                trimmed = trimmed.replacingOccurrences(of: ",", with: ".")
            } else {
                trimmed.removeAll { $0 == "," }
            }
        } else if commas > 0 {
            if commas == 1 {
                trimmed = trimmed.replacingOccurrences(of: ",", with: ".")
            } else {
                trimmed.removeAll { $0 == "," }
            }
        } else if dots > 1 {
            trimmed.removeAll { $0 == "." }
        }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}
