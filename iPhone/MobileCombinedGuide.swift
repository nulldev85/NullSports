import SwiftUI

/// Stable display IDs only. Native provider numbers remain untouched in their
/// own stores and are used for all playback and archive requests.
final class MobileProviderStreamRegistry {
    private let defaults: UserDefaults
    private var ids: [String: Int]
    private var next: Int
    private static let key = "Lineup.combinedGuide.streamIDs.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        next = -1
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        var used: Set<Int> = []
        ids = [:]
        for key in saved.keys.sorted() {
            guard let value = saved[key], value < 0, value > Int.min / 2,
                  used.insert(value).inserted else { continue }
            ids[key] = value
        }
        next = min(-1, (ids.values.min() ?? 0) - 1)
    }

    func id(provider: UUID, stream: Int) -> Int {
        let key = "\(provider.uuidString)|\(stream)"
        if let known = ids[key] { return known }
        let value = next
        next -= 1
        ids[key] = value
        return value
    }

    func save() { defaults.set(try? JSONEncoder().encode(ids), forKey: Self.key) }
}

struct MobileCombinedGuideView: View {
    @Environment(SportsLibrary.self) private var root
    @State private var combined: SportsLibrary?
    @State private var fullscreen = false
    var isActive = true
    var onFullscreenChange: (Bool) -> Void = { _ in }
    let onPlay: (XtreamStream) -> Void

    var body: some View {
        Group {
            if let combined {
                MobileGuideView(isActive: isActive, onFullscreenChange: { value in
                    fullscreen = value; onFullscreenChange(value)
                }, onPlay: onPlay)
                    .environment(combined)
            } else if root.enabledProfiles.isEmpty {
                LineupUnavailableView("No enabled providers", systemImage: "tv",
                    description: Text("Enable a service in Settings → IPTV."))
            } else {
                ProgressView("Loading your providers…")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !fullscreen { MobileProviderAvailabilityNotice(root: root) }
        }
        .task(id: root.eventChannelsInputs + [AnyHashable(isActive)]) {
            guard isActive else { return }
            let result = await root.combinedGuide { guide in
                if !Task.isCancelled { combined = guide }
            }
            guard !Task.isCancelled else { return }
            combined = result
        }
    }
}

struct MobileProviderAvailabilityNotice: View {
    let root: SportsLibrary
    var body: some View {
        let failed = root.enabledProfiles.filter { root.providerProblems[$0.id] != nil }
        if !failed.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(failed) { profile in
                    Label("\(profile.name): \(root.providerProblems[profile.id] ?? "Unavailable")", systemImage: "exclamationmark.triangle")
                        .font(.inter(.caption2, .semibold)).lineLimit(2)
                }
            }
            .foregroundStyle(LineupStyle.secondary)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading).background(LineupStyle.background)
        }
    }
}
