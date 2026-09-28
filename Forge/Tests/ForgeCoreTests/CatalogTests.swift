import Foundation
import XCTest
@testable import ForgeCore

final class CatalogTests: XCTestCase {
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/Resources/exercises.json")

    lazy var catalog: ExerciseCatalog = try! ExerciseCatalog.load(contentsOf: Self.catalogURL)
    lazy var index = ExerciseSearchIndex(exercises: catalog.exercises)

    func testCatalogIsLargeAndWellFormed() throws {
        XCTAssertGreaterThan(catalog.exercises.count, 750)
        let ids = catalog.exercises.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
        let names = catalog.exercises.map { $0.name.lowercased() }
        XCTAssertEqual(Set(names).count, names.count, "names must be unique")
        for exercise in catalog.exercises {
            XCTAssertFalse(exercise.isCustom)
            XCTAssertFalse(exercise.id.hasPrefix("custom-"), "built-in ids never collide with custom ones")
            if !["Sauna", "Cold Plunge"].contains(exercise.name) {
                XCTAssertNotEqual(exercise.primaryMuscle, .other, exercise.name)
            }
            XCTAssertFalse(exercise.secondaryMuscles.contains(exercise.primaryMuscle), exercise.name)
        }
    }

    func testEveryMuscleEquipmentAndTrackingTypeIsRepresented() {
        let muscles = Set(catalog.exercises.flatMap(\.allMuscles))
        for muscle in MuscleGroup.allCases where muscle != .other {
            XCTAssertTrue(muscles.contains(muscle), "no exercise trains \(muscle)")
        }
        let tracking = Set(catalog.exercises.map(\.tracking))
        XCTAssertEqual(tracking, Set(TrackingType.allCases))
        let categories = Set(catalog.exercises.map(\.category))
        XCTAssertEqual(categories, Set(ExerciseCategory.allCases))
    }

    /// Stable identifiers are a promise to users' history. If this test
    /// fails, an existing exercise was renamed or removed — restore its id.
    func testWellKnownIdentifiersNeverChange() {
        let ids = Set(catalog.exercises.map(\.id))
        for id in [
            "bench-press-barbell", "squat-barbell", "deadlift-barbell", "overhead-press-barbell",
            "pull-up", "push-up", "romanian-deadlift-barbell", "lat-pulldown-cable", "plank",
            "running", "rowing-machine", "kettlebell-swing", "burpee", "hip-thrust-barbell",
            "bicep-curl-dumbbell", "triceps-rope-pushdown", "leg-press-machine", "farmers-walk-dumbbell",
        ] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }

    func testSearchRanksNamePrefixFirst() {
        let results = index.search("bench")
        XCTAssertTrue(results.prefix(6).allSatisfy { $0.name.hasPrefix("Bench") })
        XCTAssertTrue(results.contains { $0.name == "Incline Bench Press (Barbell)" })
        let prefixCount = results.filter { $0.name.hasPrefix("Bench") }.count
        XCTAssertTrue(results.prefix(prefixCount).allSatisfy { $0.name.hasPrefix("Bench") }, "all prefix matches come first")
    }

    func testUsageBoostBreaksTiesWithinARank() {
        let boosted = index.search("bench", boost: ["bench-press-barbell": 40, "bench-press-dumbbell": 3])
        XCTAssertEqual(boosted.first?.id, "bench-press-barbell")
        XCTAssertEqual(boosted.dropFirst().first?.id, "bench-press-dumbbell")
        // A boost never lifts a weaker match above a better one.
        let incline = index.search("bench", boost: ["incline-bench-press-barbell": 1000])
        XCTAssertTrue(incline.first?.name.hasPrefix("Bench") ?? false)
    }

    func testSearchIsForgiving() {
        XCTAssertEqual(index.search("pushup").first?.name, "Push-Up")
        XCTAssertEqual(index.search("PUSH UP").first?.name, "Push-Up")
        XCTAssertEqual(index.search("rdl").first?.name.hasPrefix("Romanian Deadlift"), true)
        XCTAssertEqual(index.search("ohp").first?.name.hasPrefix("Overhead Press"), true)
        XCTAssertTrue(index.search("farmers walk").contains { $0.name == "Farmer's Walk (Dumbbell)" })
        XCTAssertTrue(index.search("db row").isEmpty == false || index.search("dumbbell row").isEmpty == false)
        XCTAssertTrue(index.search("curl dumbbell").contains { $0.name == "Bicep Curl (Dumbbell)" })
        XCTAssertTrue(index.search("zzzz").isEmpty)
    }

    func testFiltersCombineWithSearch() {
        let filter = ExerciseSearchIndex.Filter(muscles: [.chest], equipment: [.dumbbell])
        let results = index.search("", filter: filter)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.equipment == .dumbbell && $0.allMuscles.contains(.chest) })
        let presses = index.search("press", filter: filter)
        XCTAssertTrue(presses.allSatisfy { $0.name.lowercased().contains("press") })
        let cardio = index.search("", filter: .init(categories: [.cardio]))
        XCTAssertTrue(cardio.contains { $0.name == "Running" })
    }

    func testNormalization() {
        XCTAssertEqual(ExerciseSearchIndex.normalize("Farmer's Walk (Dumbbell)"), "farmer s walk dumbbell")
        XCTAssertEqual(ExerciseSearchIndex.normalize("  Crème  Brûlée!! "), "creme brulee")
    }
}

final class DemoDataTests: XCTestCase {
    func testDemoDataSeedsConsistentHistory() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let catalog = try ExerciseCatalog.load(contentsOf: CatalogTests.catalogURL)
        try DemoData.seed(into: db, catalog: catalog, now: Fixtures.date(28))
        XCTAssertEqual(try db.routines.routines().count, 5)
        let summaries = try db.workouts.summaries()
        XCTAssertEqual(summaries.count, 32)
        XCTAssertTrue(summaries.allSatisfy { $0.setCount > 0 })
        let ids = Set(catalog.exercises.map(\.id))
        for routine in try db.routines.routines() {
            for id in routine.allExerciseIDs {
                XCTAssertTrue(ids.contains(id), "demo routine uses unknown exercise \(id)")
            }
        }
        let book = RecordBook(records: try db.workouts.setRecords())
        XCTAssertFalse(book.prsByWorkout.isEmpty, "progressive demo data should produce records")
    }
}
