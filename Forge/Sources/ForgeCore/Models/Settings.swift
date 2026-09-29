import Foundation

public enum AppearanceMode: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case system
    case dark
    case light

    public static var fallback: AppearanceMode { .system }
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

public struct PlateStock: Hashable, Codable, Sendable, Identifiable {
    /// In the inventory's own unit (kg plates or lb plates).
    public var weight: Double
    /// How many pairs are available (a pair = one per side).
    public var pairs: Int

    public var id: Double { weight }

    public init(weight: Double, pairs: Int) {
        self.weight = weight
        self.pairs = pairs
    }

    enum CodingKeys: String, CodingKey { case weight, pairs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weight = c.value(.weight, default: 0)
        pairs = c.value(.pairs, default: 0)
    }

    public static let standardKilograms: [PlateStock] = [
        PlateStock(weight: 25, pairs: 4),
        PlateStock(weight: 20, pairs: 4),
        PlateStock(weight: 15, pairs: 2),
        PlateStock(weight: 10, pairs: 2),
        PlateStock(weight: 5, pairs: 2),
        PlateStock(weight: 2.5, pairs: 2),
        PlateStock(weight: 1.25, pairs: 2),
        PlateStock(weight: 0.5, pairs: 2),
    ]

    public static let standardPounds: [PlateStock] = [
        PlateStock(weight: 45, pairs: 6),
        PlateStock(weight: 35, pairs: 2),
        PlateStock(weight: 25, pairs: 2),
        PlateStock(weight: 10, pairs: 2),
        PlateStock(weight: 5, pairs: 2),
        PlateStock(weight: 2.5, pairs: 2),
    ]
}

public struct AppSettings: Hashable, Codable, Sendable {
    // Units
    public var weightUnit: WeightUnit
    public var distanceUnit: DistanceUnit
    public var lengthUnit: LengthUnit

    // Workout logging
    public var defaultRestSeconds: Int
    public var autoStartRestTimer: Bool
    public var restTimerSound: Bool
    public var restTimerHaptics: Bool
    public var restTimerNotifications: Bool
    public var keepScreenOn: Bool
    public var showRPE: Bool
    public var weeklyGoal: Int
    /// "Get ready" seconds before a timed set's countdown starts.
    public var timedSetLeadIn: Int

    // Interval timers
    public var timerVoice: Bool
    public var timerBeeps: Bool
    public var timerHaptics: Bool
    public var timerBackgroundAudio: Bool
    public var timerAnnounceRemaining: Bool
    public var defaultLeadIn: Int

    // Calendar: 1 = Sunday … 7 = Saturday, 0 = follow the system.
    public var firstWeekday: Int

    // Plates
    public var barWeightKg: Double
    public var barWeightLb: Double
    public var platesKg: [PlateStock]
    public var platesLb: [PlateStock]

    // Appearance
    public var accent: String
    public var appearance: AppearanceMode

    // Data safety
    public var autoBackupEnabled: Bool
    public var autoExportEnabled: Bool

    public init(
        weightUnit: WeightUnit = .kg,
        distanceUnit: DistanceUnit = .kilometers,
        lengthUnit: LengthUnit = .centimeters,
        defaultRestSeconds: Int = 90,
        autoStartRestTimer: Bool = true,
        restTimerSound: Bool = true,
        restTimerHaptics: Bool = true,
        restTimerNotifications: Bool = true,
        keepScreenOn: Bool = true,
        showRPE: Bool = false,
        weeklyGoal: Int = 3,
        timedSetLeadIn: Int = 5,
        timerVoice: Bool = true,
        timerBeeps: Bool = true,
        timerHaptics: Bool = true,
        timerBackgroundAudio: Bool = true,
        timerAnnounceRemaining: Bool = true,
        defaultLeadIn: Int = 10,
        firstWeekday: Int = 0,
        barWeightKg: Double = 20,
        barWeightLb: Double = 45,
        platesKg: [PlateStock] = PlateStock.standardKilograms,
        platesLb: [PlateStock] = PlateStock.standardPounds,
        accent: String = "sage",
        appearance: AppearanceMode = .system,
        autoBackupEnabled: Bool = true,
        autoExportEnabled: Bool = true
    ) {
        self.weightUnit = weightUnit
        self.distanceUnit = distanceUnit
        self.lengthUnit = lengthUnit
        self.defaultRestSeconds = defaultRestSeconds
        self.autoStartRestTimer = autoStartRestTimer
        self.restTimerSound = restTimerSound
        self.restTimerHaptics = restTimerHaptics
        self.restTimerNotifications = restTimerNotifications
        self.keepScreenOn = keepScreenOn
        self.showRPE = showRPE
        self.weeklyGoal = weeklyGoal
        self.timedSetLeadIn = timedSetLeadIn
        self.timerVoice = timerVoice
        self.timerBeeps = timerBeeps
        self.timerHaptics = timerHaptics
        self.timerBackgroundAudio = timerBackgroundAudio
        self.timerAnnounceRemaining = timerAnnounceRemaining
        self.defaultLeadIn = defaultLeadIn
        self.firstWeekday = firstWeekday
        self.barWeightKg = barWeightKg
        self.barWeightLb = barWeightLb
        self.platesKg = platesKg
        self.platesLb = platesLb
        self.accent = accent
        self.appearance = appearance
        self.autoBackupEnabled = autoBackupEnabled
        self.autoExportEnabled = autoExportEnabled
    }

    /// Defaults appropriate to the device's region.
    public static func defaults(usesMetric: Bool) -> AppSettings {
        var settings = AppSettings()
        if !usesMetric {
            settings.weightUnit = .lb
            settings.distanceUnit = .miles
            settings.lengthUnit = .inches
        }
        return settings
    }

    enum CodingKeys: String, CodingKey {
        case weightUnit, distanceUnit, lengthUnit
        case defaultRestSeconds, autoStartRestTimer, restTimerSound, restTimerHaptics, restTimerNotifications
        case keepScreenOn, showRPE, weeklyGoal, timedSetLeadIn
        case timerVoice, timerBeeps, timerHaptics, timerBackgroundAudio, timerAnnounceRemaining, defaultLeadIn
        case firstWeekday, barWeightKg, barWeightLb, platesKg, platesLb
        case accent, appearance, autoBackupEnabled, autoExportEnabled
    }

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weightUnit = c.value(.weightUnit, default: d.weightUnit)
        distanceUnit = c.value(.distanceUnit, default: d.distanceUnit)
        lengthUnit = c.value(.lengthUnit, default: d.lengthUnit)
        defaultRestSeconds = c.value(.defaultRestSeconds, default: d.defaultRestSeconds)
        autoStartRestTimer = c.value(.autoStartRestTimer, default: d.autoStartRestTimer)
        restTimerSound = c.value(.restTimerSound, default: d.restTimerSound)
        restTimerHaptics = c.value(.restTimerHaptics, default: d.restTimerHaptics)
        restTimerNotifications = c.value(.restTimerNotifications, default: d.restTimerNotifications)
        keepScreenOn = c.value(.keepScreenOn, default: d.keepScreenOn)
        showRPE = c.value(.showRPE, default: d.showRPE)
        weeklyGoal = c.value(.weeklyGoal, default: d.weeklyGoal)
        timedSetLeadIn = c.value(.timedSetLeadIn, default: d.timedSetLeadIn)
        timerVoice = c.value(.timerVoice, default: d.timerVoice)
        timerBeeps = c.value(.timerBeeps, default: d.timerBeeps)
        timerHaptics = c.value(.timerHaptics, default: d.timerHaptics)
        timerBackgroundAudio = c.value(.timerBackgroundAudio, default: d.timerBackgroundAudio)
        timerAnnounceRemaining = c.value(.timerAnnounceRemaining, default: d.timerAnnounceRemaining)
        defaultLeadIn = c.value(.defaultLeadIn, default: d.defaultLeadIn)
        firstWeekday = c.value(.firstWeekday, default: d.firstWeekday)
        barWeightKg = c.value(.barWeightKg, default: d.barWeightKg)
        barWeightLb = c.value(.barWeightLb, default: d.barWeightLb)
        platesKg = c.value(.platesKg, default: d.platesKg)
        platesLb = c.value(.platesLb, default: d.platesLb)
        accent = c.value(.accent, default: d.accent)
        appearance = c.value(.appearance, default: d.appearance)
        autoBackupEnabled = c.value(.autoBackupEnabled, default: d.autoBackupEnabled)
        autoExportEnabled = c.value(.autoExportEnabled, default: d.autoExportEnabled)
    }

    public var units: UnitPreferences {
        UnitPreferences(weight: weightUnit, distance: distanceUnit, length: lengthUnit)
    }

    /// Bar weight in kilograms for the current unit's bar.
    public var barWeightInKilograms: Double {
        weightUnit == .kg ? barWeightKg : WeightUnit.lb.toKilograms(barWeightLb)
    }

    public var plateInventory: [PlateStock] {
        weightUnit == .kg ? platesKg : platesLb
    }

    public func calendar(base: Calendar = .current) -> Calendar {
        var calendar = base
        if (1...7).contains(firstWeekday) {
            calendar.firstWeekday = firstWeekday
        }
        return calendar
    }
}
