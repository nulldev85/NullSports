import Foundation
import MetricKit
import CryptoKit

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

    /// Keep Apple's original stack addresses and binary UUIDs for symbolication.
    /// The payload contains its own app/OS metadata; never attribute a report
    /// from an earlier version to the build currently running.
    struct Diagnostic: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let begin: Date
        let end: Date
        let summary: String
        let json: String

        nonisolated init(begin: Date, end: Date, summary: String, data: Data) {
            id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            self.begin = begin
            self.end = end
            self.summary = summary
            // Bound both the in-memory history and its persisted copy. Do not
            // retain an unusually large stack tree on an already strained phone.
            json = data.count <= 2 * 1024 * 1024
                ? String(decoding: data, as: UTF8.self)
                : "Apple diagnostic exceeded the 2 MB local limit."
        }

        nonisolated static func keepingLatest(_ incoming: [Self], alongside saved: [Self]) -> [Self] {
            var seen: Set<String> = []
            return Array((incoming + saved).sorted { $0.end > $1.end }
                .filter { seen.insert($0.id).inserted }.prefix(6))
        }
    }

    @Published private(set) var reports: [Report] = []
    @Published private(set) var diagnostics: [Diagnostic] = []
    private let subscriber = MetricSubscriber()
    private let diagnosticWrites = LatestSnapshotQueue<Int, [Diagnostic]>()
    private var diagnosticRestore: Task<[Diagnostic], Never>?
    private var started = false

    private init() {
        reports = Self.read()
    }

    /// At launch: iOS hands over the day's report to a subscriber the app
    /// has added by then.
    func start() {
        guard !started else { return }
        started = true
        let restore = Task.detached(priority: .utility) {
            (try? Data(contentsOf: Self.diagnosticURL()))
                .flatMap { try? JSONDecoder().decode([Diagnostic].self, from: $0) } ?? []
        }
        diagnosticRestore = restore
        Task { [weak self] in
            let saved = await restore.value
            self?.diagnostics = Diagnostic.keepingLatest([], alongside: (self?.diagnostics ?? []) + saved)
        }
        subscriber.received = { new in
            Task { @MainActor in MobileDeviceReports.shared.add(new) }
        }
        subscriber.receivedDiagnostics = { new in
            Task { @MainActor in
                let device = MobileDeviceReports.shared
                let saved = await device.diagnosticRestore?.value ?? []
                device.diagnostics = Diagnostic.keepingLatest(new, alongside: device.diagnostics + saved)
                device.diagnosticRestore = nil
                device.diagnosticWrites.submit(key: 0, value: device.diagnostics) { reports in
                    await Task.detached(priority: .utility) { () -> Void in
                        try? JSONEncoder().encode(reports).write(to: Self.diagnosticURL(), options: .atomic)
                    }.value
                }
            }
        }
        MXMetricManager.shared.add(subscriber)
    }

    func exportedReport() async -> String {
        let reports = reports, diagnostics = diagnostics
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let installed = "Installed at export: \(version) (\(build)); \(ProcessInfo.processInfo.operatingSystemVersionString)"
        return await Task.detached(priority: .utility) {
            let metrics = reports.map { report in
                "\(report.begin.formatted()) – \(report.end.formatted()) · version \(report.version)\n"
                    + report.lines.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
            }
            let details = diagnostics.map { "\($0.summary)\n\($0.json)" }
            return ([installed, "Apple reporting periods and versions shown below may precede this build."]
                + metrics + details).joined(separator: "\n\n")
        }.value
    }

    nonisolated private static func diagnosticURL() -> URL {
        fileURL().deletingLastPathComponent().appendingPathComponent("lineup-device-diagnostics.json")
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

/// Serialize detailed payloads on a utility queue regardless of the thread
/// MetricKit uses to deliver them.
private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
    var received: (([MobileDeviceReports.Report]) -> Void)?
    var receivedDiagnostics: (([MobileDeviceReports.Diagnostic]) -> Void)?
    private let diagnosticProcessing = DispatchQueue(label: "Lineup.deviceDiagnostics", qos: .utility)

    func didReceive(_ payloads: [MXMetricPayload]) {
        received?(payloads.map(MobileDeviceReports.report(from:)))
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let received = receivedDiagnostics
        diagnosticProcessing.async {
            received?(payloads.sorted { $0.timeStampEnd > $1.timeStampEnd }.prefix(6).map { payload in
                let summary = "\(payload.hangDiagnostics?.count ?? 0) hangs, "
                    + "\(payload.cpuExceptionDiagnostics?.count ?? 0) CPU reports, "
                    + "\(payload.crashDiagnostics?.count ?? 0) crashes"
                return .init(begin: payload.timeStampBegin, end: payload.timeStampEnd,
                    summary: summary, data: payload.jsonRepresentation())
            })
        }
    }
}
