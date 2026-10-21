#if os(tvOS)
import SwiftUI
import UIKit

/// Tracks real press lifetimes rather than inferring release from repeated
/// focus commands. Kept separate from UIKit so holds/cancellation are testable.
@MainActor
final class TVSeekPressSession {
    private(set) var direction: Double?
    private(set) var id: UUID?
    private var beganAt: Double = 0
    private var lastFrame: Double = 0
    var onBegin: (Double) -> Void = { _ in }
    var onFrame: (Double, Double, Double) -> Void = { _, _, _ in }
    var onEnd: () -> Void = {}

    func begin(_ direction: Double, at now: Double) {
        guard self.direction != direction else { return }
        end()
        self.direction = direction
        id = UUID()
        beganAt = now
        lastFrame = now
        onBegin(direction)
    }

    func frame(at now: Double) {
        guard let direction else { return }
        let delta = min(max(now - lastFrame, 0), 0.1)
        lastFrame = now
        onFrame(direction, max(0, now - beganAt), delta)
    }

    func end(_ direction: Double? = nil) {
        guard let current = self.direction, direction == nil || direction == current else { return }
        self.direction = nil
        id = nil
        onEnd()
    }
}

/// Attach the hold recognizers to the active player host view, where tvOS
/// delivers Siri Remote press events. The seek bar's SwiftUI move command
/// handles short clicks; this recognizer owns the held-press lifecycle.
struct TVSeekRemoteInput: UIViewRepresentable {
    let active: Bool
    let onBegin: (Double) -> Void
    let onFrame: (Double, Double, Double) -> Void
    let onEnd: () -> Void

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.session.onBegin = onBegin
        view.session.onFrame = onFrame
        view.session.onEnd = onEnd
        view.active = active
        view.installRecognizersIfNeeded()
        if !active {
            DispatchQueue.main.async { [weak view] in
                guard let view, !view.active else { return }
                view.finish()
            }
        }
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        let session = TVSeekPressSession()
        var active = false
        private weak var installedView: UIView?
        private var recognizers: [UILongPressGestureRecognizer] = []
        private var displayLink: CADisplayLink?
        private lazy var displayTarget = DisplayTarget(owner: self)

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installRecognizersIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installRecognizersIfNeeded()
        }

        func installRecognizersIfNeeded() {
            guard let window, let host = playerHostView, host.window === window else { return }
            guard installedView !== host else { return }
            detach()
            installedView = host
            for type in [UIPress.PressType.leftArrow, .rightArrow] {
                let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
                // Short clicks are handled by SwiftUI's onMoveCommand.
                press.minimumPressDuration = 0.22
                press.allowedPressTypes = [NSNumber(value: type.rawValue)]
                press.cancelsTouchesInView = false
                press.delegate = self
                host.addGestureRecognizer(press)
                recognizers.append(press)
            }
        }

        private var playerHostView: UIView? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    return controller.view
                }
                responder = current.next
            }
            return window?.rootViewController?.view
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            active && installedView?.window != nil && UIApplication.shared.applicationState == .active
                && (press.type == .leftArrow || press.type == .rightArrow)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { false }

        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            let direction = direction(for: recognizer.allowedPressTypes)
            switch recognizer.state {
            case .began where active:
                session.begin(direction, at: ProcessInfo.processInfo.systemUptime)
                if displayLink == nil {
                    let link = CADisplayLink(target: displayTarget, selector: #selector(DisplayTarget.tick(_:)))
                    link.add(to: .main, forMode: .common)
                    displayLink = link
                }
            case .ended, .cancelled, .failed:
                session.end(direction)
                if session.direction == nil { displayLink?.invalidate(); displayLink = nil }
            default: break
            }
        }

        private func direction(for pressTypes: [NSNumber]) -> Double {
            pressTypes.first?.intValue == UIPress.PressType.leftArrow.rawValue ? -1 : 1
        }

        func frame() {
            guard active, window != nil else { finish(); return }
            session.frame(at: ProcessInfo.processInfo.systemUptime)
        }

        func finish() {
            displayLink?.invalidate()
            displayLink = nil
            session.end()
        }

        func detach() {
            displayLink?.invalidate()
            displayLink = nil
            for recognizer in recognizers { installedView?.removeGestureRecognizer(recognizer) }
            recognizers.removeAll()
            installedView = nil
            // Removing a representable can happen during a SwiftUI update.
            if let id = session.id {
                DispatchQueue.main.async { [session] in
                    guard session.id == id else { return }
                    session.end()
                }
            }
        }

        private final class DisplayTarget: NSObject {
            weak var owner: Probe?
            init(owner: Probe) { self.owner = owner; super.init() }
            @objc func tick(_ link: CADisplayLink) { owner?.frame() }
        }
    }
}
#endif
