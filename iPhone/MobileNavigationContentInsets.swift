import UIKit

/// A custom bar outside TabView must also be represented in the embedded
/// UIKit controller's safe area. An outer SwiftUI inset can be lost at the
/// TabView/NavigationStack hosting boundary, so this is its single owner.
@MainActor
final class MobileNavigationContentInsets {
    private struct Entry {
        weak var controller: UIViewController?
        var originalBottom: CGFloat
        var appliedBottom: CGFloat
        var observer: LayoutObserver? = nil
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    func apply(to controller: UIViewController, above boundary: UIView, onLayout: (() -> Void)? = nil) {
        // A NavigationStack can be hosted inside the tab's own controller.
        // Reserve space on its navigation container so pushed pages inherit
        // the same clearance without finding or modifying individual lists.
        // Scope ownership to the stable tab root. SwiftUI can install its
        // navigation child after the first reservation. A new recipient
        // replaces that reservation; it must never inherit a second copy.
        let key = ObjectIdentifier(controller)
        let recipient = navigationContainer(in: controller) ?? controller
        guard let view = recipient.viewIfLoaded, let window = view.window,
              boundary.window === window, view.bounds.height > 0 else { return }
        if let previous = entries[key], previous.controller !== recipient {
            entries.removeValue(forKey: key)
            restore(previous)
            controller.viewIfLoaded?.layoutIfNeeded()
        }
        let current = recipient.additionalSafeAreaInsets.bottom
        var entry = entries[key] ?? Entry(controller: recipient, originalBottom: current, appliedBottom: current)
        // A UIHostingController owns its complete view hierarchy. The
        // existing SwiftUI UIViewRepresentable reports its layout until a
        // UIKit navigation container is available for this observer.
        if entry.observer == nil, recipient is UINavigationController, let onLayout {
            let observer = LayoutObserver(frame: view.bounds)
            observer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            observer.isUserInteractionEnabled = false
            observer.isOpaque = false
            observer.accessibilityElementsHidden = true
            observer.onLayout = onLayout
            view.addSubview(observer)
            entry.observer = observer
        }
        if abs(current - entry.appliedBottom) > 0.5 {
            // Preserve an inset changed by another owner since our last pass.
            entry.originalBottom = current
        }
        let viewBottom = view.convert(view.bounds, to: window).maxY
        let covered = max(0, viewBottom - boundary.convert(boundary.bounds, to: window).minY)
        // Window protection (the home indicator) is already supplied by
        // UIKit. Measure it independently of the inset we own to avoid
        // feeding our previous adjustment back into the next measurement.
        let systemBottom = max(0, viewBottom - (window.bounds.maxY - window.safeAreaInsets.bottom))
        let bottom = max(entry.originalBottom, covered - systemBottom)
        entry.appliedBottom = bottom
        entries[key] = entry
        guard abs(current - bottom) > 0.5 else { return }
        var insets = recipient.additionalSafeAreaInsets
        insets.bottom = bottom
        recipient.additionalSafeAreaInsets = insets
    }

    private func navigationContainer(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let navigation = navigationContainer(in: child) { return navigation }
        }
        return nil
    }

    func restore() {
        for entry in entries.values { restore(entry) }
        entries.removeAll()
    }

    private func restore(_ entry: Entry) {
        entry.observer?.onLayout = nil
        entry.observer?.removeFromSuperview()
        guard let controller = entry.controller,
              abs(controller.additionalSafeAreaInsets.bottom - entry.appliedBottom) <= 0.5 else { return }
        var insets = controller.additionalSafeAreaInsets
        insets.bottom = entry.originalBottom
        controller.additionalSafeAreaInsets = insets
    }

    /// Observe the actual navigation viewport so a late native safe-area
    /// update or rotation is remeasured, even when the outer bar stays put.
    private final class LayoutObserver: UIView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); onLayout?() }
    }
}
