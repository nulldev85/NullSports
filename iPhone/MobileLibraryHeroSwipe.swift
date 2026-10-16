import SwiftUI
import UIKit

/// Decide the axis before recognition. A SwiftUI DragGesture recognizes in
/// both directions even if onEnded later ignores the vertical translation.
/// Rejecting vertical input here leaves Library's own scroll/pull untouched.
struct MobileLibraryHeroSwipe: UIGestureRecognizerRepresentable {
    let onInteractionChanged: (Bool) -> Void
    let onSwipe: (Int) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.name = "Lineup.libraryHeroSwipe"
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began:
            onInteractionChanged(true)
        case .ended:
            onInteractionChanged(false)
            let movement = pan.translation(in: pan.view)
            guard abs(movement.x) > 40, abs(movement.x) > abs(movement.y) * 1.25 else { return }
            onSwipe(movement.x < 0 ? 1 : -1)
        case .cancelled, .failed:
            onInteractionChanged(false)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.25
        }
    }
}
