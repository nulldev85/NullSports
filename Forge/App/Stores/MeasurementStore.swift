import SwiftUI

@MainActor
@Observable
final class MeasurementStore {
    private(set) var all: [BodyMeasurement] = []

    private let database: AppDatabase
    private let feedback: Feedback

    init(database: AppDatabase, feedback: Feedback) {
        self.database = database
        self.feedback = feedback
        reload()
    }

    func reload() {
        do {
            all = try database.measurements.all()
        } catch {
            feedback.report(error, while: "load your measurements")
        }
    }

    func entries(_ kind: MeasurementKind) -> [BodyMeasurement] {
        all.filter { $0.kind == kind }.sorted { $0.measuredAt < $1.measuredAt }
    }

    func latest(_ kind: MeasurementKind) -> BodyMeasurement? {
        all.filter { $0.kind == kind }.max { $0.measuredAt < $1.measuredAt }
    }

    /// Change from the previous entry to the latest.
    func change(_ kind: MeasurementKind) -> Double? {
        let list = entries(kind)
        guard list.count >= 2 else { return nil }
        return list[list.count - 1].value - list[list.count - 2].value
    }

    var trackedKinds: [MeasurementKind] {
        let used = Set(all.map(\.kind))
        return MeasurementKind.allCases.filter { used.contains($0) }
    }

    func save(_ measurement: BodyMeasurement) {
        do {
            try database.measurements.save(measurement)
            reload()
        } catch {
            feedback.report(error, while: "save the measurement")
        }
    }

    func delete(_ id: UUID) {
        do {
            try database.measurements.delete(id: id)
            reload()
        } catch {
            feedback.report(error, while: "delete the measurement")
        }
    }
}
