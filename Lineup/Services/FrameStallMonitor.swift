#if os(tvOS)
import Combine
import QuartzCore
import UIKit

/// Every time the screen stood still.
///
/// The screen draws once a frame, a sixtieth of a second apart, from the main
/// thread. When something holds that thread -- decoding a payload, sorting a
/// list, laying out a row of cards -- the next frame waits for it, and on the
/// television that wait is the remote "getting stuck" and then catching up.
/// Reasoning about which of those it is has not been enough, so this measures
/// it: each gap between frames longer than a quarter of a second, when it
/// happened, how long it was, which tab was up and what the background
/// refresh was doing at the time.
///
/// It is always on, like `StartupTrace`. A frame callback that compares two
/// numbers costs nothing that matters, and it keeps the last hundred stalls.
@MainActor
final class FrameStallMonitor: ObservableObject {
    static let shared = FrameStallMonitor()

    struct Stall: Identifiable {
        let id = UUID()
        let at: Date
        let seconds: Double
        let tab: String
        /// The background refresh's step at the time, when one was running.
        let refresh: String?
    }

    @Published private(set) var stalls: [Stall] = []
    /// The tab on screen, kept by the tab bar.
    var tab = "Sports"
    /// Where a provider refresh is up to, read at each stall.
    weak var refresh: DataRefreshProgress?

    static let threshold: CFTimeInterval = 0.25
    static let capacity = 100

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    private init() {}

    /// Begins watching frames. Calling it again does nothing.
    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // A gap that spans the app being in the background is not a stall.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.last = 0 }
        }
    }

    fileprivate func frame(at timestamp: CFTimeInterval) {
        defer { last = timestamp }
        guard last > 0, UIApplication.shared.applicationState == .active else { return }
        let gap = timestamp - last
        guard gap >= Self.threshold else { return }
        record(seconds: gap)
    }

    func record(seconds: Double, at date: Date = Date()) {
        let status = refresh?.status
        let refreshing = status.flatMap { $0.completed ? nil : $0.detail }
        stalls.append(Stall(at: date, seconds: seconds, tab: tab, refresh: refreshing))
        if stalls.count > Self.capacity { stalls.removeFirst(stalls.count - Self.capacity) }
    }

    func clear() { stalls = [] }

    /// Newest first, one line each, then how they add up by tab.
    var report: String {
        guard !stalls.isEmpty else {
            return "No stalls recorded since Lineup opened.\n\nA stall is any moment the screen stood still for a quarter of a second or more."
        }
        let time = Date.FormatStyle.dateTime.hour().minute().second()
        var lines = ["\(stalls.count) stalls of a quarter second or more, newest first.", ""]
        for stall in stalls.reversed() {
            var line = "\(stall.at.formatted(time))  \(String(format: "%.2f", stall.seconds)) s  \(stall.tab)"
            if let refresh = stall.refresh { line += "  · while \(refresh)" }
            lines.append(line)
        }
        lines.append("")
        let byTab = Dictionary(grouping: stalls, by: \.tab)
        for (tab, group) in byTab.sorted(by: { $0.value.count > $1.value.count }) {
            let total = group.reduce(0) { $0 + $1.seconds }
            let duringRefresh = group.filter { $0.refresh != nil }.count
            lines.append("\(tab): \(group.count) stalls, \(String(format: "%.1f", total)) s in all, \(duringRefresh) during a refresh")
        }
        return lines.joined(separator: "\n")
    }

    /// The display link holds its target strongly; this holds the monitor
    /// weakly so neither keeps the other alive.
    /// The link calls it on the main run loop, where it was added.
    @MainActor
    private final class Ticker: NSObject {
        weak var monitor: FrameStallMonitor?
        init(_ monitor: FrameStallMonitor) { self.monitor = monitor }
        @objc func tick(_ link: CADisplayLink) {
            monitor?.frame(at: link.timestamp)
        }
    }
}
#endif
