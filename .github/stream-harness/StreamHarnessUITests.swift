// TEMPORARY design harness -- never part of the app. Shows the stream list in
// each state it can be in and photographs it, moving focus with the remote.
import XCTest
import ObjectiveC

final class StreamHarnessUITests: XCTestCase {
    override class func setUp() {
        super.setUp()
        StreamHarnessQuiescence.disable()
    }

    override func setUp() {
        continueAfterFailure = true
    }

    /// Everything found: the tabs, the rows, focus moving down the list and
    /// back up onto a tab, and a tab chosen.
    func test1All() {
        capture("all", steps: [
            ("row1", .down), ("row2", .down), (nil, .down), (nil, .down), ("row5", .down),
            (nil, .down), (nil, .down), ("deep", .down), (nil, .down), (nil, .down), ("end", .down),
            (nil, .up), (nil, .up), (nil, .up), (nil, .up), (nil, .up), (nil, .up), (nil, .up),
            (nil, .up), (nil, .up), (nil, .up), ("tabs", .up), ("tab-null", .right),
            ("null-chosen", .select), ("tab-matt", .right), ("matt-chosen", .select),
            ("tab-vod", .right), ("vod-chosen", .select)
        ])
    }

    func test2Partial() { capture("partial", steps: [("row1", .down)]) }
    func test3Waiting() { capture("waiting", steps: []) }
    func test4Matt() { capture("matt", steps: [("row1", .down)]) }
    func test5Missing() { capture("vodmissing", steps: [("all", .left), ("all-chosen", .select)]) }
    func test6Episode() { capture("episode", steps: [("row1", .down)]) }

    private func capture(_ scenario: String, steps: [(String?, XCUIRemote.Button)]) {
        let app = XCUIApplication()
        app.launchArguments = ["-StreamHarness", scenario]
        if let backdrop = ProcessInfo.processInfo.environment["STREAM_BACKDROP"] {
            app.launchArguments += ["-StreamHarnessBackdrop", backdrop]
        }
        app.launch()
        pause(6)
        save("tv-\(scenario)-00")
        var count = 0
        for (name, button) in steps {
            XCUIRemote.shared.press(button)
            pause(1.4)
            if let name {
                count += 1
                save(String(format: "tv-%@-%02d-%@", scenario, count, name))
            }
        }
        app.terminate()
        pause(1)
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
        if let directory = ProcessInfo.processInfo.environment["STREAM_SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent(name + ".png"))
        }
    }
}

/// XCUITest waits for the app to go idle around every event, and an app with
/// a spinner never does. The waits are switched off; the test sleeps itself.
enum StreamHarnessQuiescence {
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
