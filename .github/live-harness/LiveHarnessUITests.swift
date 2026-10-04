// TEMPORARY design harness -- never part of the app. Drives the Live tab with
// the remote and saves what the screen shows after each press.
import XCTest
import ObjectiveC

final class LiveHarnessUITests: XCTestCase {
    override class func setUp() {
        super.setUp()
        LiveHarnessQuiescence.disable()
    }

    override func setUp() {
        continueAfterFailure = true
    }

    /// The default theme gets the long walk: launch, into the rails and the
    /// grid, a preview, and focus moving away from the previewing game.
    func test1Signal() {
        capture(theme: "signal", steps: [
            ("down", .down), ("down2", .down), ("right", .right), ("select", .select),
            ("down-after-preview", .down), ("left", .left), ("up", .up), ("up2", .up)
        ])
    }

    func test2Velvet() {
        capture(theme: "velvet", steps: [("down", .down), ("down2", .down), ("select", .select)])
    }

    func test3OLED() {
        capture(theme: "seaGlass", steps: [("down", .down), ("down2", .down), ("select", .select)])
    }

    func test4GraphiteIce() {
        capture(theme: "graphiteIce", steps: [("down", .down), ("down2", .down), ("select", .select)])
    }

    func test5NoFollows() {
        capture(theme: "signal", steps: [("down", .down)], extra: ["-LiveHarnessNoFollows"], prefix: "nofollow")
    }

    private func capture(theme: String, steps: [(String, XCUIRemote.Button)],
                         extra: [String] = [], prefix: String? = nil) {
        let name = prefix ?? theme
        let app = XCUIApplication()
        app.launchArguments = ["-LiveHarness", "-LiveHarnessTheme", theme] + extra
        app.launch()
        pause(14)
        shot("\(name)-00-launch")
        for (index, step) in steps.enumerated() {
            XCUIRemote.shared.press(step.1)
            pause(step.1 == .select ? 6 : 2.5)
            shot(String(format: "%@-%02d-%@", name, index + 1, step.0))
        }
        app.terminate()
        pause(2)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func shot(_ name: String) {
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
