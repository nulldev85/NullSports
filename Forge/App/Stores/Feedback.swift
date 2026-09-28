import SwiftUI

/// Transient, app-wide messages (saved, errors, recovery notices).
@MainActor
@Observable
final class Feedback {
    private(set) var toast: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, style: Toast.Style = .info, duration: TimeInterval = 2.6) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.35)) {
            toast = Toast(message: message, style: style)
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
            }
        }
    }

    func report(_ error: Error, while action: String) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        show("Couldn't \(action). \(detail)", style: .error, duration: 5)
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation { toast = nil }
    }
}
