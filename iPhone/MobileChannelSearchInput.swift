import SwiftUI
import UIKit

/// UIKit owns text/cursor/composition state. Editing events go straight to the
/// debounced search store; completed-result renders never write into the field.
struct MobileChannelSearchInput: UIViewRepresentable {
    let search: MobileChannelSearch

    func makeCoordinator() -> Coordinator { Coordinator(search: search) }

    func makeUIView(context: Context) -> UITextField {
        let field = ChannelSearchTextField()
        field.text = search.query
        field.borderStyle = .none
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: roundedUIFont(17, .regular))
        field.adjustsFontForContentSizeCategory = true
        field.textColor = UIColor(LineupStyle.lightPurple)
        field.attributedPlaceholder = NSAttributedString(string: "Search channels", attributes: [
            .foregroundColor: UIColor(LineupStyle.lightPurple.opacity(0.55))
        ])
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .always
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityLabel = "Search channels"
        field.accessibilityIdentifier = "ChooseAnotherChannelSearch"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.search = search
        // Do not assign text here: a result publication can arrive while the
        // next query is being typed, or while an IME has marked text.
    }

    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        field.removeTarget(coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        field.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var search: MobileChannelSearch
        init(search: MobileChannelSearch) { self.search = search }

        @objc func edited(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            search.search(field.text ?? "")
        }

        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            search.search("")
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

private final class ChannelSearchTextField: UITextField {
    private var requestedFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !requestedFocus else { return }
        requestedFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.becomeFirstResponder()
        }
    }
}
