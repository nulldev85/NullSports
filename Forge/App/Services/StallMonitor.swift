import SwiftUI

/// UI tests only: notes every time the main thread is busy for longer than
/// a few frames, with the screen it happened on, so CI can show exactly
/// where the app stutters (and prove when it doesn't).
///
/// A watchdog thread asks the main thread to run a tiny block every few
/// milliseconds and times how long it takes to get a turn. Lines go to
/// `Library/Caches/forge-stalls.log` in the app's container.
final class StallMonitor: @unchecked Sendable {
    static let shared = StallMonitor()

    /// Main-thread blocks longer than this are logged (about three frames
    /// at 60 Hz, where a hitch becomes visible).
    private let threshold: Double = 0.048
    private let lock = NSLock()
    private let fileLock = NSLock()
    private var context = "Launch"
    private var isRunning = false
    private let started = Date()
    private var file: FileHandle?

    static var isEnabled: Bool { AppEnvironment.isUITest }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isEnabled, !isRunning else { return }
        isRunning = true
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("forge-stalls.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        file = try? FileHandle(forWritingTo: url)
        file?.seekToEndOfFile()
        let test = ProcessInfo.processInfo.environment["FORGE_TEST_NAME"] ?? "run"
        append("=== launch \(test) \(ISO8601DateFormatter().string(from: started))")
        let thread = Thread { [weak self] in self?.watch() }
        thread.name = "forge.stall-monitor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The screen or action now on screen (shown next to any stall).
    static func note(_ context: String) {
        guard isEnabled else { return }
        shared.lock.lock()
        shared.context = context
        shared.lock.unlock()
    }

    private func watch() {
        while true {
            let sent = DispatchTime.now().uptimeNanoseconds
            let turn = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { turn.signal() }
            turn.wait()
            let waited = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000_000
            if waited >= threshold {
                lock.lock()
                let screen = context
                lock.unlock()
                let at = Date().timeIntervalSince(started)
                append(String(format: "stall %4.0f ms  at %6.2f s  %@", waited * 1000, at, screen))
            }
            usleep(8_000)
        }
    }

    private func append(_ line: String) {
        fileLock.lock()
        defer { fileLock.unlock() }
        file?.write(Data((line + "\n").utf8))
    }
}

extension View {
    /// Labels stalls that happen while this screen is showing (UI tests).
    func stallContext(_ name: String) -> some View {
        onAppear { StallMonitor.note(name) }
    }
}
