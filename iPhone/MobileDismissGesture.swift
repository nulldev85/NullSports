import SwiftUI
import UIKit

enum MobileDismissPolicy {
    static func shouldDismiss(x: CGFloat, y: CGFloat, projectedY: CGFloat) -> Bool {
        y > 24 && y > abs(x) * 1.3 && (y > 110 || projectedY > 230)
    }
}

struct MobileDismissGesture: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: CGFloat = 0
    @State private var completing = false
    @State private var exitOffset: CGFloat = 0
    let enabled: Bool
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .offset(y: reduceMotion ? 0 : (completing ? exitOffset : drag))
            .scaleEffect(reduceMotion ? 1 : 1 - min((completing ? exitOffset : drag) / 1800, 0.08))
            .opacity(reduceMotion ? 1 : 1 - min((completing ? exitOffset : drag) / 1200, 0.25))
            .animation(completing || reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: drag == 0)
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .updating($drag) { value, state, _ in
                        guard enabled, value.translation.height > abs(value.translation.width) * 1.3 else { return }
                        state = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        guard enabled, !completing,
                              MobileDismissPolicy.shouldDismiss(x: value.translation.width, y: value.translation.height,
                                                               projectedY: value.predictedEndTranslation.height) else { return }
                        if reduceMotion { onDismiss(); return }
                        // Finish from the release position before tearing down VLC.
                        // The video stays alive during the outgoing movement.
                        exitOffset = max(0, value.translation.height)
                        completing = true
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.22)) {
                                exitOffset = UIScreen.main.bounds.height
                            } completion: {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { onDismiss() }
                                completing = false
                                exitOffset = 0
                            }
                        }
                    }, including: enabled ? .all : .none
            )
            .accessibilityAction(.escape) { if enabled { onDismiss() } }
            .onChange(of: enabled) { _, active in
                if !active { completing = false; exitOffset = 0 }
            }
    }
}
