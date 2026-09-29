import Darwin
import SwiftUI

/// UI tests only: notes every time the main thread is busy for longer than
/// a few frames, with the screen it happened on and what the main thread
/// was running, so CI can show exactly where the app stutters and why (and
/// prove when it doesn't).
///
/// A watchdog thread asks the main thread to run a tiny block every few
/// milliseconds and times how long it takes to get a turn. While the main
/// thread is late, the watchdog briefly pauses it to read its call stack.
/// Lines go to `Library/Caches/forge-stalls.log` in the app's container.
final class StallMonitor: @unchecked Sendable {
    static let shared = StallMonitor()

    /// Main-thread blocks longer than this are logged (about three frames
    /// at 60 Hz, where a hitch becomes visible).
    private let threshold: Double = 0.048
    /// Stacks are read when a stall is noticed, then this often while it
    /// lasts, up to `maxSamples` per stall.
    private let sampleInterval: Double = 0.1
    private let maxSamples = 4
    private let maxFrames = 96
    private let lock = NSLock()
    private let fileLock = NSLock()
    private var context = "Launch"
    private var isRunning = false
    private let started = Date()
    private var file: FileHandle?

    // Stack sampling. The buffers are allocated up front: nothing may
    // allocate or lock while the main thread is paused.
    private var mainThread: mach_port_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private let registers = UnsafeMutablePointer<natural_t>.allocate(capacity: 128)
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: 128)
    /// User-space addresses fit in 47 bits; higher bits can carry tags
    /// (Swift marks async frames in the saved frame pointer).
    private let addressMask: UInt = 0x0000_7FFF_FFFF_FFFF

    static var isEnabled: Bool { AppEnvironment.isUITest }

    /// Call on the main thread.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isEnabled, !isRunning else { return }
        isRunning = true
        if Thread.isMainThread {
            mainThread = mach_thread_self()
            let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
            stackHigh = top
            stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
        }
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
            let sent = DispatchTime.now()
            let turn = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { turn.signal() }
            var samples: [(at: Double, stack: [UInt])] = []
            var deadline = sent + threshold
            while turn.wait(timeout: deadline) == .timedOut {
                if samples.count < maxSamples {
                    let at = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000_000
                    samples.append((at, sampleMainStack()))
                }
                deadline = DispatchTime.now() + sampleInterval
            }
            let waited = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000_000
            if waited >= threshold {
                lock.lock()
                let screen = context
                lock.unlock()
                let at = Date().timeIntervalSince(started)
                var lines = [String(format: "stall %4.0f ms  at %6.2f s  %@", waited * 1000, at, screen)]
                for sample in samples {
                    let label = String(format: "  @%.0f ", sample.at * 1000)
                    lines += sample.stack.map { label + describe($0) }
                }
                append(lines.joined(separator: "\n"))
            }
            usleep(8_000)
        }
    }

    // MARK: Stacks

    /// The main thread's call stack, innermost first.
    private func sampleMainStack() -> [UInt] {
        // Everything the walk needs is copied first; while the thread is
        // paused only locals and preallocated buffers are touched.
        let thread = mainThread
        let bounds = (low: stackLow, high: stackHigh)
        guard thread != 0, thread_suspend(thread) == KERN_SUCCESS else { return [] }
        let count = walkPausedStack(thread, low: bounds.low, high: bounds.high)
        thread_resume(thread)
        return Array(UnsafeBufferPointer(start: frames, count: count))
    }

    /// Reads the paused main thread's registers and follows its frame
    /// pointers. Runs while the main thread is paused, so it only reads
    /// memory: no allocation, no locks, no Objective-C or Swift runtime.
    private func walkPausedStack(_ thread: mach_port_t, low: UInt, high: UInt) -> Int {
        #if arch(arm64)
        // ARM_THREAD_STATE64: x0–x28, fp, lr, sp, pc, cpsr.
        let flavor: thread_state_flavor_t = 6
        var stateCount: mach_msg_type_number_t = 68
        let fpIndex = 29, lrIndex = 30, pcIndex = 32
        #elseif arch(x86_64)
        // x86_THREAD_STATE64: rax … rbp (6) … rip (16) ….
        let flavor: thread_state_flavor_t = 4
        var stateCount: mach_msg_type_number_t = 42
        let fpIndex = 6, lrIndex = -1, pcIndex = 16
        #else
        return 0
        #endif
        let state = registers
        guard thread_get_state(thread, flavor, state, &stateCount) == KERN_SUCCESS else { return 0 }
        let mask = addressMask
        let limit = maxFrames
        // 64-bit registers, read as two 32-bit words (little-endian).
        func register(_ index: Int) -> UInt {
            UInt(state[index * 2]) | UInt(state[index * 2 + 1]) &<< 32
        }
        func isOnStack(_ fp: UInt) -> Bool {
            fp >= low && fp + 16 <= high && fp & 7 == 0
        }
        var count = 0
        frames[count] = register(pcIndex) & mask
        count += 1
        var fp = register(fpIndex) & mask
        // A leaf that hasn't saved its frame yet still has its caller in lr.
        if lrIndex >= 0 {
            let lr = register(lrIndex) & mask
            let firstReturn = isOnStack(fp) ? UnsafePointer<UInt>(bitPattern: fp + 8)!.pointee & mask : 0
            if lr != 0, lr != firstReturn {
                frames[count] = lr
                count += 1
            }
        }
        while count < limit, isOnStack(fp) {
            let record = UnsafePointer<UInt>(bitPattern: fp)!
            let next = record[0] & mask
            let returnAddress = record[1] & mask
            guard returnAddress != 0 else { break }
            frames[count] = returnAddress
            count += 1
            guard next > fp else { break }
            fp = next
        }
        return count
    }

    /// "image base address symbol": CI symbolicates the app's own frames
    /// from the image base and address.
    private func describe(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let path = info.dli_fname else {
            return "? 0x0 0x\(String(address, radix: 16))"
        }
        let image = (String(cString: path) as NSString).lastPathComponent
        let base = UInt(bitPattern: info.dli_fbase)
        var line = "\(image) 0x\(String(base, radix: 16)) 0x\(String(address, radix: 16))"
        if let symbol = info.dli_sname {
            line += " " + String(cString: symbol)
        }
        return line
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
