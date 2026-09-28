import SwiftUI

@MainActor
@Observable
final class SettingsStore {
    private(set) var value: AppSettings
    private let database: AppDatabase
    private let feedback: Feedback

    init(database: AppDatabase, feedback: Feedback) {
        self.database = database
        self.feedback = feedback
        let usesMetric = Locale.current.measurementSystem != .us
        value = (try? database.meta.loadSettings(default: .defaults(usesMetric: usesMetric))) ?? .defaults(usesMetric: usesMetric)
    }

    func reload() {
        if let loaded = try? database.meta.loadSettings(default: value) {
            value = loaded
        }
    }

    func update(_ change: (inout AppSettings) -> Void) {
        var copy = value
        change(&copy)
        guard copy != value else { return }
        value = copy
        do {
            try database.meta.saveSettings(copy)
        } catch {
            feedback.report(error, while: "save your settings")
        }
    }

    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.value[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    var units: UnitPreferences { value.units }
    var calendar: Calendar { value.calendar() }
    var accentColor: Color { Theme.accent(named: value.accent) }

    var colorScheme: ColorScheme? {
        switch value.appearance {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    // MARK: Unit helpers for input fields

    /// Binding that shows kilograms in the athlete's unit.
    func weightBinding(_ kilograms: Binding<Double?>) -> Binding<Double?> {
        let unit = value.weightUnit
        return Binding(
            get: { kilograms.wrappedValue.map { Self.clean(unit.fromKilograms($0)) } },
            set: { kilograms.wrappedValue = $0.map { unit.toKilograms($0) } }
        )
    }

    func distanceBinding(_ meters: Binding<Double?>, short: Bool) -> Binding<Double?> {
        let unit = value.distanceUnit
        return Binding(
            get: { meters.wrappedValue.map { Self.clean(unit.fromMeters($0, short: short)) } },
            set: { meters.wrappedValue = $0.map { unit.toMeters($0, short: short) } }
        )
    }

    /// Removes floating-point noise from unit round trips (102.0000001 → 102).
    static func clean(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
