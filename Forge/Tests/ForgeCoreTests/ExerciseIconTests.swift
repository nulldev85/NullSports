import Foundation
import XCTest
@testable import ForgeCore

final class ExerciseIconTests: XCTestCase {
    private lazy var catalog: ExerciseCatalog = try! ExerciseCatalog.load(contentsOf: CatalogTests.catalogURL)

    func testEveryGlyphDrawsInsideItsGrid() {
        for glyph in ExerciseGlyph.allCases {
            let ops = glyph.ops
            XCTAssertFalse(ops.isEmpty, "\(glyph) draws something")
            XCTAssertEqual(ops.count, glyph.source.split(separator: ";").count, "every step of \(glyph) parses")
            for op in ops {
                for point in Self.points(of: op) {
                    XCTAssert((-1...25).contains(point.x) && (-1...25).contains(point.y), "\(glyph) stays in its grid: \(point)")
                }
            }
        }
    }

    func testEquipmentExercisesShowTheirEquipment() {
        let expected: [Equipment: ExerciseGlyph] = [
            .kettlebell: .kettlebell, .dumbbell: .dumbbell, .barbell: .barbell, .ezBar: .ezBar, .trapBar: .trapBar,
            .smithMachine: .smithMachine, .machine: .machine, .cable: .cable, .band: .band, .plate: .plate,
            .landmine: .landmine, .medicineBall: .medicineBall, .stabilityBall: .stabilityBall, .foamRoller: .foamRoller,
            .suspension: .suspension, .rings: .rings, .sled: .sled, .sandbag: .sandbag, .jumpRope: .jumpRope,
            .battleRope: .battleRope,
        ]
        for exercise in catalog.exercises {
            guard let glyph = expected[exercise.equipment] else { continue }
            XCTAssertEqual(exercise.icon, .glyph(glyph), exercise.name)
        }
    }

    func testEveryBodyweightMovementHasItsOwnPicture() throws {
        let unmatched = catalog.exercises
            .filter { [.none, .other, .cardioMachine].contains($0.equipment) && $0.icon == .glyph(.stand) }
            .map(\.name)
        XCTAssertEqual(unmatched, [], "no bodyweight exercise falls back to the plain standing figure")

        let expectations: [String: ExerciseIcon] = [
            "Push-Up": .glyph(.pushUp),
            "Pull-Up": .glyph(.pullUp),
            "Chin-Up": .glyph(.pullUp),
            "Hanging Leg Raise": .glyph(.hangingLegRaise),
            "Lying Leg Raise": .glyph(.legRaise),
            "Walking Lunge": .glyph(.lunge),
            "Jump Squat": .glyph(.jump),
            "Bodyweight Squat": .glyph(.squat),
            "Plank": .glyph(.plank),
            "Side Plank": .glyph(.sidePlank),
            "Burpee": .glyph(.burpee),
            "Glute Bridge": .glyph(.gluteBridge),
            "Downward Dog": .glyph(.downwardDog),
            "Handstand Push-Up": .glyph(.handstand),
            "Box Jump": .glyph(.boxJump),
            "Tire Flip": .glyph(.tire),
            "Walking": .symbol(["figure.walk"], fallback: .run),
            "Table Tennis": .symbol(["figure.table.tennis"], fallback: .stand),
            "Tennis": .symbol(["figure.tennis"], fallback: .stand),
            "Rowing Machine": .symbol(["figure.rower"], fallback: .stand),
        ]
        for (name, icon) in expectations {
            let exercise = try XCTUnwrap(catalog.exercises.first { $0.name == name }, name)
            XCTAssertEqual(exercise.icon, icon, name)
        }
    }

    func testCustomExercisesGetPicturesToo() {
        let sandbag = Exercise(id: Exercise.newCustomID(), name: "Sandbag Bear Hug Carry", primaryMuscle: .fullBody, equipment: .sandbag, isCustom: true)
        XCTAssertEqual(sandbag.icon, .glyph(.sandbag))
        let pushUp = Exercise(id: Exercise.newCustomID(), name: "Archer Push-Up Hold", primaryMuscle: .chest, equipment: .none, isCustom: true)
        XCTAssertEqual(pushUp.icon, .glyph(.pushUp))
        let unknown = Exercise(id: Exercise.newCustomID(), name: "Something New", primaryMuscle: .chest, equipment: .none, category: .mobility, isCustom: true)
        XCTAssertEqual(unknown.icon, .glyph(.sideStretch), "falls back to its category's figure")
    }

    private static func points(of op: GlyphOp) -> [GlyphPoint] {
        switch op {
        case .stroke(let points, _), .clearStroke(let points, _), .fill(let points), .clearFill(let points):
            return points
        case .disc(let center, _), .clearDisc(let center, _):
            return [center]
        case .roundedRect(let x, let y, let width, let height, _), .clearRoundedRect(let x, let y, let width, let height, _):
            return [GlyphPoint(x: x, y: y), GlyphPoint(x: x + width, y: y + height)]
        }
    }
}
