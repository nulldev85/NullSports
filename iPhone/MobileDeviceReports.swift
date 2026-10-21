import Foundation
import MetricKit

/// Apple's own account of how the app ran on this phone, from MetricKit:
/// how long launches took, hangs, scrolling hitches, CPU, data and memory.
/// iOS sends one a day at most, so the first comes a day or so after a
/// build is installed. The last fourteen are kept, on the phone only, and
/// shown under Settings > Diagnostics > Device Reports.
@MainActor
final class MobileDeviceReports: ObservableObject {
    static let shared = MobileDeviceReports()

    struct Line: Codable, Equatable, Sendable {
        let label: String
        let value: String
    }

    struct Report: Codable, Equatable, Identifiable, Sendable {
        var id: Date { begin }
        let begin: Date
        let end: Date
        let version: String
        let lines: [Line]
    }

    @Published private(set) var reports: [Report] = []
    private let subscriber = MetricSubscriber()
    private var started = false

    private init() {
        reports = Self.read()
    }

    /// At launch: iOS hands over the day's report to a subscriber the app
    /// has added by then.
    func start() {
        guard !started else { return }
        started = true
        subscriber.received = { new in
            Task { @MainActor in MobileDeviceReports.shared.add(new) }
        }
        MXMetricManager.shared.add(subscriber)
    }

    private func add(_ new: [Report]) {
        let kept = (new + reports.filter { old in !new.contains { $0.begin == old.begin } })
            .sorted { $0.begin > $1.begin }
            .prefix(14)
        reports = Array(kept)
        let saved = reports
        Task.detached(priority: .utility) {
            try? JSONEncoder().encode(saved).write(to: Self.fileURL(), options: .atomic)
        }
    }

    nonisolated private static func fileURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lineup-device-reports.json")
    }

    private static func read() -> [Report] {
        (try? Data(contentsOf: fileURL())).flatMap { try? JSONDecoder().decode([Report].self, from: $0) } ?? []
    }

    // MARK: Reading a payload

    nonisolated static func report(from payload: MXMetricPayload) -> Report {
        var lines: [Line] = []
        func add(_ label: String, _ value: String?) {
            if let value { lines.append(Line(label: label, value: value)) }
        }
        if let launch = payload.applicationLaunchMetrics {
            add("Launch to first frame", spread(launch.histogrammedTimeToFirstDraw, each: "launch"))
            add("Back from the background", spread(launch.histogrammedApplicationResumeTime, each: "return"))
        }
        if let hangs = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
            add("Hangs", spread(hangs, each: "hang") ?? "None")
        }
        if let hitches = payload.animationMetrics?.scrollHitchTimeRatio {
            add("Scroll hitches", String(format: "%.1f ms a second", hitches.value))
        }
        if let cpu = payload.cpuMetrics?.cumulativeCPUTime { add("CPU time", duration(cpu)) }
        if let time = payload.applicationTimeMetrics {
            add("On screen", duration(time.cumulativeForegroundTime))
            add("Sound in the background", duration(time.cumulativeBackgroundAudioTime))
        }
        if let network = payload.networkTransferMetrics {
            add("Downloaded on Wi-Fi", size(network.cumulativeWifiDownload))
            add("Downloaded on cellular", size(network.cumulativeCellularDownload))
        }
        if let memory = payload.memoryMetrics?.peakMemoryUsage { add("Peak memory", size(memory)) }
        if let writes = payload.diskIOMetrics?.cumulativeLogicalWrites { add("Written to storage", size(writes)) }
        return Report(begin: payload.timeStampBegin, end: payload.timeStampEnd,
                      version: payload.latestApplicationVersion, lines: lines)
    }

    /// "0.84 s on average, 12 launches": the buckets' middles, weighted by
    /// how many fell in each. Nil when none did.
    nonisolated private static func spread(_ histogram: MXHistogram<UnitDuration>, each: String) -> String? {
        var count = 0
        var total = 0.0
        let buckets = histogram.bucketEnumerator
        while let bucket = buckets.nextObject() as? MXHistogramBucket<UnitDuration> {
            let middle = (bucket.bucketStart.converted(to: .seconds).value
                + bucket.bucketEnd.converted(to: .seconds).value) / 2
            count += bucket.bucketCount
            total += middle * Double(bucket.bucketCount)
        }
        guard count > 0 else { return nil }
        return String(format: "%.2f s on average", total / Double(count)) + ", \(count) \(each)\(count == 1 ? "" : "s")"
    }

    nonisolated private static func duration(_ value: Measurement<UnitDuration>) -> String {
        let seconds = Int(value.converted(to: .seconds).value.rounded())
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    nonisolated private static func size(_ value: Measurement<UnitInformationStorage>) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value.converted(to: .bytes).value), countStyle: .file)
    }
}

/// MetricKit calls its subscriber off the main thread.
private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
    var received: (([MobileDeviceReports.Report]) -> Void)?

    func didReceive(_ payloads: [MXMetricPayload]) {
        received?(payloads.map(MobileDeviceReports.report(from:)))
    }
}
