import SwiftUI

/// Transient, app-wide messages (saved, errors, recovery notices).
@MainActor
@Observable
final class Feedback {
    private(set) var toast: Toast?
    private var dismissTask: Task<Void, Never>?

    /// A toast with an `action` (such as Undo) stays up a little longer.
    func show(_ message: String, style: Toast.Style = .info, duration: TimeInterval = 2.6, action: ToastAction? = nil) {
        dismissTask?.cancel()
        let duration = action == nil ? duration : max(duration, 5)
        withAnimation(Motion.lively) {
            toast = Toast(message: message, style: style, action: action)
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(Motion.smooth) { self?.toast = nil }
            }
        }
    }

    func report(_ error: Error, while action: String) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        show("Couldn't \(action). \(detail)", style: .error, duration: 5)
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(Motion.smooth) { toast = nil }
    }
}
