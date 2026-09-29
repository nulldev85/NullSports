import UIKit
import UniformTypeIdentifiers

/// Apple's file picker, used only for copies: saving a copy of a file
/// wherever the athlete chooses (iCloud Drive, say), or bringing in a copy
/// of a file they pick.
///
/// Opening a folder or file in place (keeping access to it afterwards)
/// isn't used: iOS can refuse that access to sideloaded apps, and the
/// picker then just sits there when the athlete taps Open. Copies never
/// need it.
@MainActor
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPicker()

    private var completion: (@MainActor ([URL]) -> Void)?

    /// Saves a copy of `file` where the athlete chooses; `completion` gets
    /// where it went, or nil if they cancelled.
    func saveCopy(of file: URL, completion: @escaping @MainActor (URL?) -> Void) {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        present(picker) { completion($0.first) }
    }

    /// Brings in a copy of the file the athlete picks, or nil if they
    /// cancelled. The copy is Forge's own, so reading it needs no access.
    func importCopy(of types: [UTType], completion: @escaping @MainActor (URL?) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        present(picker) { completion($0.first) }
    }

    private func present(_ picker: UIDocumentPickerViewController, completion: @escaping @MainActor ([URL]) -> Void) {
        guard let presenter = Self.topViewController() else {
            completion([])
            return
        }
        // Only one picker answers at a time.
        finish([])
        self.completion = completion
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish([])
    }

    private func finish(_ urls: [URL]) {
        let handler = completion
        completion = nil
        handler?(urls)
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
