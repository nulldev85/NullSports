import XCTest

/// Drives the main flows on a simulator with demo data and captures
/// screenshots (exported as CI artifacts) of every major screen.
final class ForgeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ForgeUITest", "-ForgeSeedDemoData"]
        // Labels this test's lines in the stall report.
        app.launchEnvironment["FORGE_TEST_NAME"] = name
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

    /// Scrolls the current screen until `element` can be tapped (lists only
    /// create rows that are on screen).
    private func reveal(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 3), element.isHittable { return true }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        return false
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

        // Each set is its own row: swiping one offers Delete, which removes
        // just that set (the first working set, so 15 working sets become 14).
        let setRows = app.cells.containing(.button, identifier: "completeSet")
        let firstWorkingSet = setRows.element(boundBy: 2)
        XCTAssertTrue(firstWorkingSet.waitForExistence(timeout: 5), "each set is a row of its own")
        XCTAssertTrue(app.staticTexts["0/15"].exists, "the warm-up doesn't count as a working set")
        firstWorkingSet.swipeLeft()
        XCTAssertTrue(tapIfExists(app.buttons["Delete"]), "swiping a set offers Delete")
        XCTAssertTrue(app.staticTexts["0/14"].waitForExistence(timeout: 5), "the swiped set is deleted")

        app.buttons["finishWorkout"].tap()
        XCTAssertTrue(app.buttons["saveFinishedWorkout"].waitForExistence(timeout: 10))
        snapshot("06-Finish")
        app.buttons["saveFinishedWorkout"].tap()
        XCTAssertTrue(app.buttons["summaryDone"].waitForExistence(timeout: 15))
        sleep(1)
        snapshot("07-Summary")
        app.buttons["summaryDone"].tap()

        tab("History")
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        snapshot("08-History")
        let latest = app.buttons.matching(identifier: "historyWorkout").firstMatch
        XCTAssertTrue(reveal(latest), "history should list the workout")
        latest.tap()
        sleep(1)
        snapshot("09-WorkoutDetail")
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
        XCTAssertTrue(reveal(app.buttons["routine-Test Builder"]), "new routine should be listed")

        tab("Exercises")
        let librarySearch = app.searchFields.firstMatch
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 10))
        snapshot("13-Exercises")
        librarySearch.tap()
        librarySearch.typeText("Zercher Sandbag")
        XCTAssertTrue(app.staticTexts["Zercher Sandbag Carry"].waitForExistence(timeout: 5), "custom exercise is saved to the library")
        librarySearch.typeText(XCUIKeyboardKey.delete.rawValue)
    }

    func testLibraryToolsAndBody() throws {
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))

        // A routine with a timed block, and the builder editing it.
        XCTAssertTrue(tapIfExists(app.buttons["folder-Conditioning"]))
        XCTAssertTrue(tapIfExists(app.buttons["routine-Cindy"]))
        XCTAssertTrue(app.buttons["startRoutineWorkout"].waitForExistence(timeout: 10))
        snapshot("21-TimedRoutine")
        XCTAssertTrue(tapIfExists(app.buttons["editRoutine"]))
        XCTAssertTrue(app.buttons["saveRoutine"].waitForExistence(timeout: 10))
        snapshot("22-RoutineBuilder")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["startRoutineWorkout"].waitForExistence(timeout: 10))

        // The timed block inside a live workout, then its timer. Both are
        // minimized so the rest of the test runs with a workout in progress.
        app.buttons["startRoutineWorkout"].tap()
        XCTAssertTrue(app.buttons["startTimedBlock"].waitForExistence(timeout: 10))
        snapshot("26-TimedBlockWorkout")
        app.buttons["startTimedBlock"].tap()
        XCTAssertTrue(app.buttons["pauseTimer"].waitForExistence(timeout: 10))
        sleep(2)
        snapshot("27-AmrapTimer")
        XCTAssertTrue(tapIfExists(app.buttons["Minimize timer"]))
        XCTAssertTrue(tapIfExists(app.buttons["minimizeWorkout"], timeout: 10))

        // Exercise detail with the demo history.
        tab("Exercises")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Bench Press (Barbell)")
        XCTAssertTrue(tapIfExists(app.buttons["exercise-Bench Press (Barbell)"], timeout: 10))
        sleep(1)
        snapshot("23-ExerciseDetail")

        tab("Timers")
        let plates = app.buttons["tool-plates"]
        XCTAssertTrue(reveal(plates), "plate calculator should be under Tools")
        plates.tap()
        sleep(1)
        snapshot("24-PlateCalculator")

        tab("Progress")
        let body = app.buttons["measurementsLink"]
        XCTAssertTrue(reveal(body), "body card should be on the dashboard")
        body.tap()
        sleep(1)
        snapshot("25-Measurements")
    }

    func testDarkModeTour() throws {
        app.terminate()
        app.launchArguments = ["-ForgeUITest", "-ForgeSeedDemoData", "-ForgeDarkMode"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        snapshot("30-DarkTrain")

        XCTAssertTrue(tapIfExists(app.buttons["folder-Strength"]))
        XCTAssertTrue(tapIfExists(app.buttons["folder-Upper / Lower"]))
        XCTAssertTrue(tapIfExists(app.buttons["routine-Upper A"]))
        XCTAssertTrue(app.buttons["startRoutineWorkout"].waitForExistence(timeout: 10))
        app.buttons["startRoutineWorkout"].tap()
        let complete = app.buttons.matching(identifier: "completeSet").firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        complete.tap()
        XCTAssertTrue(app.buttons["skipRest"].waitForExistence(timeout: 5))
        snapshot("31-DarkWorkout")
        XCTAssertTrue(tapIfExists(app.buttons["minimizeWorkout"]))

        tab("History")
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        snapshot("32-DarkHistory")

        tab("Progress")
        XCTAssertTrue(app.navigationBars["Progress"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("33-DarkProgress")
        XCTAssertTrue(tapIfExists(app.buttons["openSettings"]))
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        snapshot("34-DarkSettings")

        // Equipment pictures next to bodyweight movement pictures.
        tab("Exercises")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("push\n")
        XCTAssertTrue(app.buttons["exercise-Push-Up"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("35-DarkExercises")
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
        let backups = app.buttons["backupsLink"]
        XCTAssertTrue(reveal(backups), "Backups & Export should be in Settings")
        backups.tap()
        XCTAssertTrue(app.navigationBars["Backups & Export"].waitForExistence(timeout: 10))
        snapshot("20-Backups")

        // The recovery scan runs on its own and ends with a result either way.
        let findMissing = app.buttons["findMissingData"]
        XCTAssertTrue(reveal(findMissing), "Find Missing Data should be in Backups")
        findMissing.tap()
        XCTAssertTrue(app.navigationBars["Find Missing Data"].waitForExistence(timeout: 10))
        let finished = NSPredicate(format: "label BEGINSWITH 'Nothing is missing' OR label BEGINSWITH 'Found ' OR label BEGINSWITH 'No backups'")
        XCTAssertTrue(app.descendants(matching: .any).matching(finished).firstMatch.waitForExistence(timeout: 60), "the scan should finish")
        sleep(1)
        snapshot("20b-FindMissingData")
    }

    func testFreshInstallOffersRestore() throws {
        app.terminate()
        app.launchArguments = ["-ForgeUITest"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["restoreBackupFile"].waitForExistence(timeout: 10), "a fresh install offers to restore a backup")
        snapshot("36-FreshInstall")

        // Progress with nothing logged yet: every card still lines up.
        tab("Progress")
        XCTAssertTrue(app.navigationBars["Progress"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("36b-FreshProgress")
    }

    func testSavingABackupCopy() throws {
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        // Copies off the iPhone go through Apple's save picker, which works
        // however the app was installed.
        XCTAssertTrue(tapIfExists(app.buttons["saveBackupCopy"], timeout: 10), "the Train screen suggests saving a copy")
        let browse = app.buttons["Browse"].firstMatch
        guard browse.waitForExistence(timeout: 15) else {
            snapshot("20c-SaveCopyPicker")
            throw XCTSkip("The system save picker isn't visible to UI tests here")
        }
        sleep(1)
        snapshot("20c-SaveCopyPicker")
        func confirmButton() -> XCUIElement? {
            ["Save", "Move", "Copy", "Export", "Done"]
                .map { app.buttons[$0].firstMatch }
                .first { $0.exists && $0.isEnabled }
        }
        // Somewhere the picker can save: this app's folder on the simulator.
        if confirmButton() == nil {
            browse.tap()
            _ = tapIfExists(app.staticTexts["On My iPhone"].firstMatch, timeout: 5)
            _ = tapIfExists(app.staticTexts["Forge"].firstMatch, timeout: 5)
            sleep(1)
        }
        guard let confirm = confirmButton() else {
            snapshot("20d-SaveCopyPicker")
            for label in ["Cancel", "Close"] where app.buttons[label].firstMatch.exists {
                app.buttons[label].firstMatch.tap()
                break
            }
            throw XCTSkip("Couldn't find a place to save in the simulator's picker")
        }
        confirm.tap()
        // Anywhere else is confirmed by name; Forge's own folder (where the
        // simulator's picker lands) is caught, since it goes with the app.
        let answer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", "Backup saved to", "Forge's own folder")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "saving the copy reaches the app")
        snapshot("20d-SaveCopyDone")
    }

    func testTimedSetsCountDown() throws {
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        XCTAssertTrue(tapIfExists(app.buttons["startEmptyWorkout"], timeout: 10))
        XCTAssertTrue(tapIfExists(app.buttons["workoutAddExercises"], timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        // (Typing an apostrophe could turn it curly.)
        search.typeText("Farmer")
        XCTAssertTrue(tapIfExists(app.buttons["pick-Farmer's Walk (Dumbbell)"], timeout: 10))
        XCTAssertTrue(tapIfExists(app.buttons["confirmAddExercises"], timeout: 10))

        // Done by time last time (the demo routine), so it's timed again:
        // each set has a countdown beside its number.
        let timer = app.buttons.matching(identifier: "setTimer").firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 10), "a farmer's walk last done by time is timed again")
        sleep(1)
        snapshot("39-TimedSets")

        // Three seconds this time, then start it.
        let time = app.textFields.matching(identifier: "Time").firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        time.tap()
        time.typeText("3")
        timer.tap()
        XCTAssertTrue(app.buttons["finishSetTimer"].waitForExistence(timeout: 5), "the countdown shows at the bottom")
        sleep(2)
        snapshot("40-SetCountdown")

        // At zero the set is ticked off by itself and the rest starts.
        XCTAssertTrue(app.buttons["skipRest"].waitForExistence(timeout: 25), "the set finishes on its own and rest starts")
        XCTAssertTrue(app.buttons["Mark set incomplete"].firstMatch.exists, "the timed set is logged")
        sleep(1)
        snapshot("41-TimedSetDone")

        // Switching back asks first, since it would clear the logged time.
        XCTAssertTrue(tapIfExists(app.buttons["Exercise options"].firstMatch))
        // A toggle in a menu can show up as a button or a switch.
        let options = [app.buttons["Track by Time"], app.switches["Track by Time"], app.descendants(matching: .any)["Track by Time"]]
        var trackByTime: XCUIElement?
        for _ in 0..<10 where trackByTime == nil {
            trackByTime = options.map(\.firstMatch).first { $0.exists }
            if trackByTime == nil { usleep(500_000) }
        }
        let item = try XCTUnwrap(trackByTime, "the exercise menu offers tracking by time")
        snapshot("42-TrackByTimeMenu")
        item.tap()

        // Switching back to distance clears the logged time, with an undo.
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "switching away from time offers an undo")
        XCTAssertFalse(app.buttons.matching(identifier: "setTimer").firstMatch.exists, "tracked by distance again")
        snapshot("43-TrackByTimeUndo")
        undo.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "setTimer").firstMatch.waitForExistence(timeout: 5), "undo brings the timed sets back")
        XCTAssertTrue(app.buttons["Mark set incomplete"].firstMatch.exists, "the logged set is kept")
    }

    func testTrackByTimeInRoutineEditor() throws {
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        XCTAssertTrue(tapIfExists(app.buttons["folder-Strength"]))
        XCTAssertTrue(tapIfExists(app.buttons["folder-Upper / Lower"]))
        XCTAssertTrue(tapIfExists(app.buttons["routine-Upper A"]))
        XCTAssertTrue(tapIfExists(app.buttons["editRoutine"], timeout: 10))
        XCTAssertTrue(app.buttons["saveRoutine"].waitForExistence(timeout: 10))

        // The first exercise's menu: switch it to time.
        XCTAssertTrue(tapIfExists(app.buttons["Exercise options"].firstMatch))
        let options = [app.buttons["Track by Time"], app.switches["Track by Time"], app.descendants(matching: .any)["Track by Time"]]
        var trackByTime: XCUIElement?
        for _ in 0..<10 where trackByTime == nil {
            trackByTime = options.map(\.firstMatch).first { $0.exists }
            if trackByTime == nil { usleep(500_000) }
        }
        try XCTUnwrap(trackByTime, "the editor's exercise menu offers tracking by time").tap()

        // The exercise's card redraws right away with a time column.
        XCTAssertTrue(app.staticTexts["TIME"].firstMatch.waitForExistence(timeout: 5), "the card switches to time straight away")
        sleep(1)
        snapshot("44-EditorTrackByTime")
        let time = app.textFields.matching(identifier: "Time").firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        time.tap()
        time.typeText("45")
        app.buttons["saveRoutine"].tap()

        // Back on the routine, the exercise reads as timed sets.
        let timed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "for 45s")).firstMatch
        XCTAssertTrue(timed.waitForExistence(timeout: 10), "the routine shows the exercise by time")
        sleep(1)
        snapshot("45-RoutineTrackByTime")
    }

    func testFinishKeepsTypedSetsAndDeleteCanBeUndone() throws {
        XCTAssertTrue(app.navigationBars["Train"].waitForExistence(timeout: 30))
        XCTAssertTrue(tapIfExists(app.buttons["folder-Strength"]))
        XCTAssertTrue(tapIfExists(app.buttons["folder-Upper / Lower"]))
        XCTAssertTrue(tapIfExists(app.buttons["routine-Upper A"]))
        XCTAssertTrue(app.buttons["startRoutineWorkout"].waitForExistence(timeout: 10))
        app.buttons["startRoutineWorkout"].tap()
        XCTAssertTrue(app.buttons["finishWorkout"].waitForExistence(timeout: 10))

        // Type reps into the first set without ticking it.
        let reps = app.textFields.matching(identifier: "Reps").firstMatch
        if reps.waitForExistence(timeout: 5) {
            reps.tap()
            reps.typeText("7")
            app.buttons["finishWorkout"].tap()
            XCTAssertTrue(app.buttons["saveFinishedWorkout"].waitForExistence(timeout: 10))
            XCTAssertTrue(reveal(app.switches["keepEnteredSets"]), "typed-in sets are offered on the Finish screen")
            snapshot("37-FinishTypedSets")
        } else {
            app.buttons["finishWorkout"].tap()
        }
        XCTAssertTrue(app.buttons["saveFinishedWorkout"].waitForExistence(timeout: 10))
        app.buttons["saveFinishedWorkout"].tap()
        XCTAssertTrue(tapIfExists(app.buttons["summaryDone"], timeout: 15))

        // Deleting from History needs a deliberate tap and can be undone.
        tab("History")
        let latest = app.buttons.matching(identifier: "historyWorkout").firstMatch
        XCTAssertTrue(reveal(latest), "history should list the workout")
        latest.swipeLeft()
        XCTAssertTrue(tapIfExists(app.buttons["Delete"]))
        XCTAssertTrue(app.buttons["toastAction"].waitForExistence(timeout: 5), "a delete offers Undo")
        snapshot("38-UndoDelete")
        app.buttons["toastAction"].tap()
    }
}
