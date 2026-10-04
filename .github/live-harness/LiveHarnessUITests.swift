// TEMPORARY design harness -- never part of the app. Drives the Live tab with
// the remote and saves what the screen shows after each press.
import XCTest
import ObjectiveC

final class LiveHarnessUITests: XCTestCase {
    private struct Step {
        let name: String?
        let button: XCUIRemote.Button
        var hold: TimeInterval = 0
        var wait: TimeInterval = 2.5
    }

    private static func shot(_ name: String, _ button: XCUIRemote.Button, wait: TimeInterval = 2.5) -> Step {
        Step(name: name, button: button, wait: wait)
    }

    private static func quiet(_ button: XCUIRemote.Button) -> Step {
        Step(name: nil, button: button, wait: 1.2)
    }

    override class func setUp() {
        super.setUp()
        LiveHarnessQuiescence.disable()
    }

    override func setUp() {
        continueAfterFailure = true
    }

    /// The Live tab: into My Teams, down to the board, a preview with focus
    /// moving on, the filter, the next row, a hold-Select menu, and Menu
    /// stopping the preview.
    func test1Live() {
        capture(steps: [
            Self.shot("rail1", .down), Self.shot("rail2", .down), Self.quiet(.down),
            Self.shot("board1", .down), Self.shot("board2", .right),
            Self.shot("preview", .select, wait: 9), Self.shot("preview-focus-moves", .right),
            Self.quiet(.right), Self.shot("filter", .up), Self.quiet(.down),
            Self.shot("row2", .down), Self.shot("stop-preview", .menu, wait: 3),
            Self.shot("upcoming-slate", .left),
            Step(name: "context-menu", button: .select, hold: 1.6, wait: 2.5)
        ], prefix: "live")
    }

    /// The Guide: across to its tab, into the grid, along a row, a preview,
    /// the sidebar, and Menu hiding the preview.
    func test2Guide() {
        capture(steps: [
            Self.quiet(.up), Self.quiet(.up),
            Self.shot("tab", .right, wait: 6),
            Self.shot("enter", .down), Self.shot("down", .down), Self.shot("down2", .down),
            Self.shot("right", .right), Self.shot("right2", .right),
            Self.shot("select", .select, wait: 9),
            Self.quiet(.left), Self.quiet(.left), Self.shot("sidebar", .left),
            Self.shot("sidebar-down", .down), Self.shot("sidebar-close", .right),
            Self.shot("menu-stops", .menu, wait: 3), Self.shot("menu-hides", .menu, wait: 3)
        ], prefix: "guide")
    }

    /// Account, top to bottom.
    func test3Account() {
        capture(steps: [
            Self.quiet(.up), Self.quiet(.up), Self.quiet(.right), Self.quiet(.right),
            Self.shot("tab", .right, wait: 5),
            Self.shot("enter", .down), Self.shot("right", .right), Self.shot("down", .down),
            Self.shot("down2", .down), Self.shot("down3", .down), Self.shot("down4", .down),
            Self.shot("down5", .down), Self.shot("down6", .down)
        ], prefix: "account")
    }

    /// Library, which has no server here: the theme and its empty state.
    func test4Library() {
        capture(steps: [
            Self.quiet(.up), Self.quiet(.up), Self.quiet(.right),
            Self.shot("tab", .right, wait: 5), Self.shot("enter", .down)
        ], prefix: "library")
    }

    /// Hold Select on a matched game, choose Start Multiview (the last item),
    /// and look at the board asking for a second game.
    func test5Multiview() {
        capture(steps: [
            Self.quiet(.down), Self.quiet(.down), Self.quiet(.down), Self.quiet(.down),
            Step(name: "menu", button: .select, hold: 1.6, wait: 2.5),
            Self.quiet(.down), Self.quiet(.down), Self.shot("multiview", .select, wait: 3),
            Self.shot("multiview-second", .right)
        ], prefix: "multiview")
    }

    /// An off night: the slate with nothing to show, and My Teams naming the
    /// teams that are not playing.
    func test6NoGames() {
        capture(steps: [Self.shot("down", .down)], extra: ["-LiveHarnessNoGames"], prefix: "nogames")
    }

    private func capture(steps: [Step], extra: [String] = [], prefix: String) {
        let name = prefix
        let app = XCUIApplication()
        app.launchArguments = ["-LiveHarness"] + extra
        // A US evening, so the slate reads the way it will for the person it
        // is for, and today's games are today's.
        app.launchEnvironment = ["TZ": "America/New_York"]
        app.launch()
        pause(14)
        save("\(name)-00-launch")
        var count = 0
        for step in steps {
            if step.hold > 0 {
                XCUIRemote.shared.press(step.button, forDuration: step.hold)
            } else {
                XCUIRemote.shared.press(step.button)
            }
            pause(step.wait)
            if let label = step.name {
                count += 1
                save(String(format: "%@-%02d-%@", name, count, label))
            }
        }
        app.terminate()
        pause(2)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["LIVE_SHOTS_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}

/// XCUITest waits for the app to go idle before and after every event, and an
/// app with a running ticker never does, so every press would sit out the
/// whole timeout. The waits are switched off; the test sleeps for itself.
enum LiveHarnessQuiescence {
    static func disable() {
        guard let process = NSClassFromString("XCUIApplicationProcess") else { return }
        let one: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
        let two: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
        if let method = class_getInstanceMethod(process, NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")) {
            method_setImplementation(method, imp_implementationWithBlock(one))
        }
        if let method = class_getInstanceMethod(process,
            NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")) {
            method_setImplementation(method, imp_implementationWithBlock(two))
        }
    }
}
