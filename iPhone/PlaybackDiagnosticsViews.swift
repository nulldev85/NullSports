import SwiftUI
import UIKit

/// Live state drawn over the video while diagnostics are on.
///
/// A black picture with working audio cannot be diagnosed after the fact, so
/// the values that decide whether a frame can appear are shown while it is
/// happening. `layer ready` is the one to read first.
struct PlaybackDiagnosticsOverlay: View {
    @ObservedObject private var diagnostics = PlaybackDiagnostics.shared
    let controller: MobilePlaybackController

    private let shown: Set<String> = [
        "engine", "awaiting surface", "host", "layer", "layer ready",
        "item status", "rate", "timeControl", "presentationSize", "video tracks",
        "vlc videoOut", "error"
    ]

    var body: some View {
        if diagnostics.isEnabled {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(diagnostics.snapshot.filter { shown.contains($0.label) }, id: \.label) { row in
                    HStack(spacing: 4) {
                        Text(row.label).foregroundStyle(.white.opacity(0.6))
                        Text(row.value)
                            .foregroundStyle(alarming(row) ? .red : .green)
                    }
                }
            }
            .font(.interDigits(9, .medium))
            .padding(6)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The two states that mean "no picture is coming".
    private func alarming(_ row: (label: String, value: String)) -> Bool {
        (row.label == "layer ready" && row.value == "NO")
            || (row.label == "video tracks" && row.value.hasPrefix("0 "))
            || (row.label == "presentationSize" && row.value == "0x0")
            || (row.label == "layer" && row.value == "none")
            || (row.label == "error" && row.value != "—")
    }
}

/// The full report, for pasting somewhere it can be read.
struct PlaybackDiagnosticsReportView: View {
    @ObservedObject private var diagnostics = PlaybackDiagnostics.shared
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(diagnostics.report)
                .font(.interDigits(11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                // On a card like the Settings rows that lead here.
                .background(LineupPanelStyle.listCard,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(16)
        }
        .background(LineupPanelStyle.listGround)
        .navigationTitle("Playback Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LineupToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = diagnostics.report
                    copied = true
                }
                .buttonStyle(LineupBarButtonStyle())
            }
            LineupToolbarItem(placement: .bottomBar) {
                Button("Clear", role: .destructive) {
                    diagnostics.clear()
                    copied = false
                }
                .buttonStyle(LineupBarButtonStyle())
            }
        }
    }
}

/// The last launch, step by step.
///
/// Always recorded, because the question it answers -- which part of a slow
/// start is actually slow -- has been guessed at twice and measured never.
/// Apple's daily reports of how the app ran on this phone.
struct DeviceReportsView: View {
    @ObservedObject private var device = MobileDeviceReports.shared

    var body: some View {
        List {
            if device.reports.isEmpty {
                Section {
                    Text("No report yet. iOS sends one a day at most, so the first comes a day or so after this version is installed.")
                        .font(.inter(15)).foregroundStyle(LineupPanelStyle.listValue)
                }
                .lineupSettingsRows()
            }
            ForEach(device.reports) { report in
                Section {
                    ForEach(report.lines, id: \.label) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(line.label).font(.inter(15, .medium)).foregroundStyle(LineupStyle.text)
                            Spacer(minLength: 8)
                            Text(line.value).font(.interDigits(15)).foregroundStyle(LineupPanelStyle.listValue)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("\(report.begin.formatted(date: .abbreviated, time: .omitted)) · version \(report.version)")
                        .lineupSettingsHeader()
                }
                .lineupSettingsRows()
            }
        }
        .lineupSettingsList()
        .navigationTitle("Device Reports")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StartupTraceReportView: View {
    @ObservedObject private var trace = StartupTrace.shared
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(trace.report)
                .font(.interDigits(11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                // On a card like the Settings rows that lead here.
                .background(LineupPanelStyle.listCard,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(16)
        }
        .background(LineupPanelStyle.listGround)
        .navigationTitle("Launch Timing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LineupToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = trace.report
                    copied = true
                }
                .buttonStyle(LineupBarButtonStyle())
            }
        }
    }
}
