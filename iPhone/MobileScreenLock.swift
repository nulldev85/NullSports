import SwiftUI
import UIKit

/// The player's screen lock: while it is on, the picture plays on, every
/// touch is ignored -- the controls, a swipe to close, a swipe to change
/// channel -- and the screen keeps the way it is turned, so a phone held
/// loosely, lying down, or in a child's hand changes nothing. One player is
/// on screen at a time, so one lock serves them all; it comes off when the
/// player closes.
@MainActor @Observable
final class MobileScreenLock {
    static let shared = MobileScreenLock()
    private(set) var isLocked = false
    /// The ways the app may turn: the iPhone's usual three, or, locked,
    /// only the way it was turned when the lock went on.
    private(set) var orientations: UIInterfaceOrientationMask = .allButUpsideDown

    func lock() {
        guard !isLocked else { return }
        isLocked = true
        switch Self.activeScene?.interfaceOrientation {
        case .landscapeLeft: orientations = .landscapeLeft
        case .landscapeRight: orientations = .landscapeRight
        case .portraitUpsideDown: orientations = .portraitUpsideDown
        default: orientations = .portrait
        }
        applyOrientations()
    }

    func unlock() {
        guard isLocked else { return }
        isLocked = false
        orientations = .allButUpsideDown
        applyOrientations()
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Asks iOS to read the allowed ways again, from the app's delegate.
    private func applyOrientations() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// The app's delegate, here for one question iOS asks it: which ways the
/// screen may turn. Everything else stays with SwiftUI.
@MainActor
final class LineupAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MobileScreenLock.shared.orientations
    }
}

/// Laid over a locked player. It takes every touch; a tap brings up the lock,
/// and holding the lock for a moment takes it off. A brush of the screen
/// can't do that, which is the point.
struct MobileScreenLockOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var badgeShown = true
    @State private var holding = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Not quite clear: a fully clear view takes no touches.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0).onEnded { _ in show() })
                .accessibilityHidden(true)
            if badgeShown {
                VStack(spacing: 10) {
                    Image(systemName: holding ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .frame(width: 60, height: 60)
                        .lineupPlayerControlGlass(Circle(), prominent: holding)
                        .scaleEffect(holding && !reduceMotion ? 1.12 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: holding)
                    Text("Hold to unlock")
                        .font(.inter(.caption, .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .lineupPlayerPanelGlass(Capsule())
                }
                .foregroundStyle(LineupStyle.mediaText)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 30) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    MobileScreenLock.shared.unlock()
                } onPressingChanged: { pressing in
                    holding = pressing
                    if pressing { hideTask?.cancel() } else { scheduleHide() }
                }
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Screen locked, and won't rotate")
                .accessibilityHint("Double-tap and hold to unlock")
                .accessibilityAction(named: "Unlock") { MobileScreenLock.shared.unlock() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: badgeShown)
        .onAppear { show() }
        .onDisappear { hideTask?.cancel() }
    }

    private func show() {
        badgeShown = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, !holding else { return }
            badgeShown = false
        }
    }
}
