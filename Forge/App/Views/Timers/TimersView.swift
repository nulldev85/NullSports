import SwiftUI

struct TimersView: View {
    @Environment(AppModel.self) private var app
    @State private var setup: TimerSetupRequest?
    @State private var tool: ToolRoute?

    enum ToolRoute: Hashable {
        case plates, oneRepMax, warmup
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let active = app.timers.active {
                        ActiveTimerCard(controller: active) {
                            app.timers.isPresented = true
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Formats", subtitle: "Tap one to set it up")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(TimerKind.allCases) { kind in
                                Button {
                                    var config = TimerConfig.standard(kind)
                                    config.leadIn = kind == .stopwatch || kind == .countdown ? min(config.leadIn, Double(app.settings.value.defaultLeadIn)) : Double(app.settings.value.defaultLeadIn)
                                    setup = TimerSetupRequest(config: config, presetID: nil, name: kind.displayName)
                                } label: {
                                    FormatTile(kind: kind)
                                }
                                .buttonStyle(.pressable)
                                .accessibilityIdentifier("timerFormat-\(kind.rawValue)")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "My Timers", subtitle: app.timers.presets.isEmpty ? "Save a setup to start it in one tap" : nil)
                        if app.timers.presets.isEmpty {
                            EmptyCard(title: "No saved timers", message: "Set up any format and tap Save as Preset.", symbol: "bookmark")
                        }
                        ForEach(app.timers.presets) { preset in
                            PresetRow(preset: preset) {
                                app.timers.start(preset.config, title: preset.name)
                            } edit: {
                                setup = TimerSetupRequest(config: preset.config, presetID: preset.id, name: preset.name)
                            } delete: {
                                app.timers.deletePreset(preset.id)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Tools")
                        NavigationLink(value: ToolRoute.plates) {
                            ToolRow(title: "Plate Calculator", subtitle: "What to load on each side", symbol: "circle.grid.2x1.fill")
                        }
                        .accessibilityIdentifier("tool-plates")
                        NavigationLink(value: ToolRoute.oneRepMax) {
                            ToolRow(title: "One-Rep Max", subtitle: "Estimate your 1RM and training loads", symbol: "chart.line.uptrend.xyaxis")
                        }
                        .accessibilityIdentifier("tool-oneRepMax")
                        NavigationLink(value: ToolRoute.warmup) {
                            ToolRow(title: "Warm-up Sets", subtitle: "A ramp up to your working weight", symbol: "flame.fill")
                        }
                        .accessibilityIdentifier("tool-warmup")
                    }
                    .buttonStyle(.pressable)
                }
                .padding(16)
                .animation(Motion.smooth, value: app.timers.active?.id)
            }
            .background(Theme.canvas)
            .navigationTitle("Timers")
            .navigationDestination(for: ToolRoute.self) { route in
                switch route {
                case .plates: PlateCalculatorView()
                case .oneRepMax: OneRepMaxView()
                case .warmup: WarmupCalculatorView()
                }
            }
            .sheet(item: $setup) { request in
                TimerSetupView(request: request)
                    .environment(app)
            }
        }
    }
}

/// The timer that's running (or waiting to be saved). Its own view, so the
/// clock ticking over redraws this card and not the whole Timers tab.
struct ActiveTimerCard: View {
    let controller: TimerController
    let open: () -> Void

    var body: some View {
        let display = controller.display
        Button(action: open) {
            HStack(spacing: 12) {
                IconBadge(symbol: controller.program.config.kind.symbolName, color: Theme.onAccent, size: 42)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.isFinished ? "\(controller.title) finished" : "\(controller.title) running")
                        .font(.app(.headline))
                        .foregroundStyle(.primary)
                    Text(display.isFinished ? "Tap to save the result" : display.clockText)
                        .font(.num(.subheadline))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(countsDown: !display.phase.countsUp))
                        .animation(Motion.numeric, value: display.clockText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .cardStyle(padding: 14)
        }
        .buttonStyle(.pressable)
    }
}

struct TimerSetupRequest: Identifiable {
    let id = UUID()
    var config: TimerConfig
    var presetID: UUID?
    var name: String
}

struct FormatTile: View {
    let kind: TimerKind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconBadge(symbol: kind.symbolName, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName)
                    .font(.app(.headline))
                    .foregroundStyle(.primary)
                Text(kind.tagline)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }
}

struct PresetRow: View {
    let preset: TimerPreset
    let start: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: preset.config.kind.symbolName)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.app(.body, .semibold))
                Text(preset.config.summary)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: start) {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start \(preset.name)")
        }
        .cardStyle(padding: 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .contextMenu {
            Button("Start", systemImage: "play.fill", action: start)
            Button("Edit", systemImage: "slider.horizontal.3", action: edit)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

struct ToolRow: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(.body, .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.app(.caption, .semibold))
                .foregroundStyle(.tertiary)
        }
        .cardStyle(padding: 12)
    }
}

/// Configure a format, then start it or save it as a preset.
struct TimerSetupView: View {
    let request: TimerSetupRequest
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var config: TimerConfig
    @State private var name: String
    @State private var savingPreset = false

    init(request: TimerSetupRequest) {
        self.request = request
        _config = State(initialValue: request.config)
        _name = State(initialValue: request.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TimerConfigForm(config: $config)
                Section {
                    Button {
                        let final = config.sanitized()
                        dismiss()
                        let timers = app.timers
                        let title = name.isEmpty ? final.kind.displayName : name
                        afterDelay(0.4) {
                            timers.start(final, title: title)
                        }
                    } label: {
                        Label("Start \(config.kind.displayName)", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("startTimer")
                }
            }
            .canvasBackground()
            .navigationTitle(request.presetID == nil ? config.kind.displayName : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.presetID == nil ? "Save as Preset" : "Save") {
                        savingPreset = true
                    }
                }
            }
            .alert(request.presetID == nil ? "Save Timer" : "Update Timer", isPresented: $savingPreset) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    app.timers.savePreset(name: name, config: config.sanitized(), id: request.presetID)
                }
            } message: {
                Text("Saved timers appear under My Timers.")
            }
        }
    }
}
