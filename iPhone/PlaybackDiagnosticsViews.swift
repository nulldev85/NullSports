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
            .font(.system(size: 9, weight: .medium, design: .monospaced))
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
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(LineupStyle.background)
        .navigationTitle("Playback diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = diagnostics.report
                    copied = true
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Clear", role: .destructive) {
                    diagnostics.clear()
                    copied = false
                }
            }
        }
    }
}

/// The last launch, step by step.
///
/// Always recorded, because the question it answers -- which part of a slow
/// start is actually slow -- has been guessed at twice and measured never.
struct StartupTraceReportView: View {
    @ObservedObject private var trace = StartupTrace.shared
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(trace.report)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(LineupStyle.background)
        .navigationTitle("Launch timing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = trace.report
                    copied = true
                }
            }
        }
    }
}
