import UIKit
import UniformTypeIdentifiers

/// Picks a folder with the system picker, presented straight from UIKit.
/// Picking a folder through SwiftUI's file importer could leave the picker's
/// Open button doing nothing, so the folder never reached the app.
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPicker()

    private var onPick: ((URL) -> Void)?

    /// Shows the picker over whatever is on screen; `onPick` gets the folder
    /// the athlete opened (nothing, if they cancel).
    func present(onPick: @escaping (URL) -> Void) {
        guard let presenter = Self.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.onPick = onPick
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let handler = onPick
        onPick = nil
        if let url = urls.first {
            handler?(url)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick = nil
    }

    /// The view controller at the top of the key window (above any sheet).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = (scene?.keyWindow ?? scene?.windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
