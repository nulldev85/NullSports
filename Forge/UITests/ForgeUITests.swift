import XCTest

/// Drives the main flows on a simulator with demo data and captures
/// screenshots (exported as CI artifacts) of every major screen.
final class ForgeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ForgeUITest", "-ForgeSeedDemoData"]
        app.launch()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "tab \(name) missing")
        button.tap()
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    func testTrainRoutineAndLogWorkout() throws {
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        snapshot("01-Train")

        XCTAssertTrue(tapIfExists(app.buttons["folder-Strength"]))
        snapshot("02-Folder")
        XCTAssertTrue(tapIfExists(app.buttons["folder-Upper / Lower"]))
        XCTAssertTrue(tapIfExists(app.buttons["routine-Upper A"]))
        XCTAssertTrue(app.buttons["startRoutineWorkout"].waitForExistence(timeout: 10))
        snapshot("03-RoutineDetail")

        app.buttons["startRoutineWorkout"].tap()
        XCTAssertTrue(app.buttons["finishWorkout"].waitForExistence(timeout: 10))
        snapshot("04-Workout")

        let complete = app.buttons.matching(identifier: "completeSet").firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        complete.tap()
        XCTAssertTrue(app.buttons["skipRest"].waitForExistence(timeout: 5), "rest timer should start after a set")
        snapshot("05-RestTimer")
        app.buttons["skipRest"].tap()

        app.buttons["finishWorkout"].tap()
        XCTAssertTrue(app.buttons["saveFinishedWorkout"].waitForExistence(timeout: 10))
        snapshot("06-Finish")
        app.buttons["saveFinishedWorkout"].tap()
        XCTAssertTrue(app.buttons["summaryDone"].waitForExistence(timeout: 15))
        snapshot("07-Summary")
        app.buttons["summaryDone"].tap()

        tab("History")
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        snapshot("08-History")
        let firstWorkout = app.cells.element(boundBy: 1)
        if firstWorkout.waitForExistence(timeout: 5) {
            firstWorkout.tap()
            sleep(1)
            snapshot("09-WorkoutDetail")
        }
    }

    func testBuildRoutineWithCustomExercise() throws {
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        XCTAssertTrue(tapIfExists(app.buttons["addMenuToolbar"]))
        XCTAssertTrue(tapIfExists(app.buttons["New Routine"]))
        let name = app.textFields["routineNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Test Builder")
        XCTAssertTrue(tapIfExists(app.buttons["addExercisesButton"]))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        snapshot("10-ExercisePicker")
        search.tap()
        search.typeText("Zercher Sandbag Carry")
        XCTAssertTrue(tapIfExists(app.buttons["createCustomExercise"]))
        XCTAssertTrue(app.buttons["saveCustomExercise"].waitForExistence(timeout: 10))
        snapshot("11-CustomExercise")
        app.buttons["saveCustomExercise"].tap()

        XCTAssertTrue(tapIfExists(app.buttons["confirmAddExercises"], timeout: 10))
        XCTAssertTrue(app.buttons["saveRoutine"].waitForExistence(timeout: 10))
        snapshot("12-RoutineEditor")
        app.buttons["saveRoutine"].tap()
        XCTAssertTrue(app.buttons["routine-Test Builder"].waitForExistence(timeout: 10), "new routine should be listed")

        tab("Exercises")
        let librarySearch = app.searchFields.firstMatch
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 10))
        snapshot("13-Exercises")
        librarySearch.tap()
        librarySearch.typeText("Zercher Sandbag")
        XCTAssertTrue(app.staticTexts["Zercher Sandbag Carry"].waitForExistence(timeout: 5), "custom exercise is saved to the library")
        librarySearch.typeText(XCUIKeyboardKey.delete.rawValue)
    }

    func testTimersProgressAndSettings() throws {
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        tab("Timers")
        XCTAssertTrue(app.buttons["timerFormat-tabata"].waitForExistence(timeout: 10))
        snapshot("14-Timers")
        app.buttons["timerFormat-tabata"].tap()
        XCTAssertTrue(app.buttons["startTimer"].waitForExistence(timeout: 10))
        snapshot("15-TimerSetup")
        app.buttons["startTimer"].tap()
        XCTAssertTrue(app.buttons["pauseTimer"].waitForExistence(timeout: 10))
        sleep(2)
        snapshot("16-TimerRunning")
        app.buttons["endTimer"].tap()
        XCTAssertTrue(tapIfExists(app.buttons["End and Log Result"]))
        XCTAssertTrue(app.buttons["saveTimerResult"].waitForExistence(timeout: 10))
        snapshot("17-TimerResult")
        app.buttons["saveTimerResult"].tap()

        tab("Progress")
        XCTAssertTrue(app.navigationBars["Progress"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("18-Progress")
        XCTAssertTrue(tapIfExists(app.buttons["openSettings"]))
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        snapshot("19-Settings")
        XCTAssertTrue(tapIfExists(app.buttons["backupsLink"]))
        XCTAssertTrue(app.navigationBars["Backups & Export"].waitForExistence(timeout: 10))
        snapshot("20-Backups")
    }
}
