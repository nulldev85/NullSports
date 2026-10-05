// TEMPORARY design harness -- never part of the app. Photographs the stream
// list on an iPhone in each state it can be in.
import XCTest
import ObjectiveC

final class StreamHarnessiOSUITests: XCTestCase {
    override class func setUp() {
        super.setUp()
        StreamHarnessiOSQuiescence.disable()
    }

    override func setUp() {
        continueAfterFailure = true
    }

    func test1All() { capture("all", scroll: true) }
    func test2Partial() { capture("partial") }
    func test3Waiting() { capture("waiting") }
    func test4Matt() { capture("matt") }
    func test5Missing() { capture("vodmissing") }
    func test6Episode() { capture("episode") }

    private func capture(_ scenario: String, scroll: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-StreamHarness", scenario]
        if let backdrop = ProcessInfo.processInfo.environment["STREAM_BACKDROP"] {
            app.launchArguments += ["-StreamHarnessBackdrop", backdrop]
        }
        app.launch()
        pause(5)
        save("phone-\(scenario)-00")
        if scroll {
            app.swipeUp()
            pause(1.5)
            save("phone-\(scenario)-01-scrolled")
            app.swipeUp()
            pause(1.5)
            save("phone-\(scenario)-02-end")
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

enum StreamHarnessiOSQuiescence {
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
