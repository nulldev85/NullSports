#if os(tvOS)
import SwiftUI

/// One thing a choice sheet offers on the television: a tile, its name, and
/// what it does.
struct TVChoice: Identifiable {
    let id: String
    let title: String
    /// The row's coloured tile. Nil for a plain choice in a long list, such
    /// as a subtitle track or a season.
    var symbol: String?
    /// An image from the asset catalog in place of the tile, such as a
    /// playback engine's own logo.
    var logo: String?
    var isSelected = false
    var isDestructive = false
    var isEnabled = true
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, logo: String? = nil, id: String? = nil, isSelected: Bool = false,
         isDestructive: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.symbol = symbol
        self.logo = logo
        self.isSelected = isSelected
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.action = action
    }
}

extension View {
    /// A short Select and a held Select are exclusive. The card must not
    /// launch playback when the viewer releases Select after opening its menu.
    func tvSelectAction(_ action: @escaping () -> Void) -> some View {
        modifier(TVSelectActionModifier(action: action))
    }

    /// The app's own sheet of choices on the television, in place of the
    /// system's alert and action sheet, which draw in tvOS's own chrome and
    /// type: a panel over the dimmed screen with a coloured tile, the
    /// question and what it means, a row a choice, and Cancel beneath. Back
    /// closes it, as it closes everything.
    func tvChoices(_ title: String, symbol: String, isPresented: Binding<Bool>,
                   message: String? = nil, cancelTitle: String = "Cancel",
                   items: @escaping () -> [TVChoice],
                   onCancel: @escaping () -> Void = {}) -> some View {
        modifier(TVChoicesModifier(isPresented: isPresented, title: title, symbol: symbol,
                                   message: message, cancelTitle: cancelTitle,
                                   items: items, onCancel: onCancel))
    }

    /// Hold Select: the app's own choices for what has focus, in place of
    /// the system's context menu.
    func tvHoldMenu(_ title: String, symbol: String, message: String? = nil,
                    items: @escaping () -> [TVChoice]) -> some View {
        modifier(TVHoldMenuModifier(title: title, symbol: symbol, message: message, items: items))
    }
}

private struct TVChoicesModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let symbol: String
    let message: String?
    let cancelTitle: String
    let items: () -> [TVChoice]
    let onCancel: () -> Void

    /// What was chosen, run once the sheet has gone: an action that opens a
    /// screen of its own must not try to present over one still leaving.
    @State private var chosen: TVChoice?

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented, onDismiss: {
            if let choice = chosen {
                chosen = nil
                choice.action()
            } else {
                onCancel()
            }
        }) {
            TVChoiceSheet(title: title, symbol: symbol, message: message, cancelTitle: cancelTitle,
                          items: items()) { choice in
                chosen = choice
                isPresented = false
            } cancel: {
                isPresented = false
            }
            .presentationBackground(.clear)
            .environment(\.tvHoldAction, nil)
        }
    }
}

/// One immutable value opens a held-item menu. A separate Boolean can present
/// a sheet before SwiftUI has delivered the newly captured action array.
struct TVHoldMenuPresentation: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let message: String?
    let items: [TVChoice]

    init?(title: String, symbol: String, message: String?, items: [TVChoice]) {
        guard !items.isEmpty else { return nil }
        self.title = title
        self.symbol = symbol
        self.message = message
        self.items = items
    }
}

private struct TVHoldMenuModifier: ViewModifier {
    let title: String
    let symbol: String
    let message: String?
    let items: () -> [TVChoice]

    @State private var presentation: TVHoldMenuPresentation?
    @State private var chosen: TVChoice?

    func body(content: Content) -> some View {
        content
            .environment(\.tvHoldAction, TVHoldAction {
                guard presentation == nil else { return }
                chosen = nil
                presentation = TVHoldMenuPresentation(title: title, symbol: symbol, message: message, items: items())
            })
            .fullScreenCover(item: $presentation, onDismiss: {
                let action = chosen
                chosen = nil
                action?.action()
            }) { snapshot in
                TVChoiceSheet(title: snapshot.title, symbol: snapshot.symbol, message: snapshot.message,
                              cancelTitle: "Cancel", items: snapshot.items) { choice in
                    chosen = choice
                    presentation = nil
                } cancel: {
                    presentation = nil
                }
                .id(snapshot.id)
                .presentationBackground(.clear)
                .environment(\.tvHoldAction, nil)
            }
    }
}

private struct TVHoldAction {
    let perform: () -> Void
}

private struct TVHoldActionKey: EnvironmentKey {
    static let defaultValue: TVHoldAction? = nil
}

private extension EnvironmentValues {
    var tvHoldAction: TVHoldAction? {
        get { self[TVHoldActionKey.self] }
        set { self[TVHoldActionKey.self] = newValue }
    }
}

private struct TVSelectActionModifier: ViewModifier {
    @Environment(\.tvHoldAction) private var hold
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let hold {
            content.highPriorityGesture(
                // tvOS has a duration-only initializer for remote presses;
                // the touch-distance overload is unavailable on this platform.
                LongPressGesture(minimumDuration: 0.5)
                    .exclusively(before: TapGesture())
                    .onEnded { press in
                        switch press {
                        case .first(true): hold.perform()
                        case .second: action()
                        default: break
                        }
                    }
            )
        } else {
            content.onTapGesture(perform: action)
        }
    }
}

/// The panel itself, centred over the dimmed screen.
private struct TVChoiceSheet: View {
    /// Held from when it opened: what it asks should not change, or empty,
    /// while it fades away.
    @State private var title: String
    @State private var symbol: String
    @State private var message: String?
    @State private var items: [TVChoice]
    let cancelTitle: String
    let choose: (TVChoice) -> Void
    let cancel: () -> Void

    init(title: String, symbol: String, message: String?, cancelTitle: String, items: [TVChoice],
         choose: @escaping (TVChoice) -> Void, cancel: @escaping () -> Void) {
        _title = State(initialValue: title)
        _symbol = State(initialValue: symbol)
        _message = State(initialValue: message)
        _items = State(initialValue: items)
        self.cancelTitle = cancelTitle
        self.choose = choose
        self.cancel = cancel
    }

    private static let rowHeight: CGFloat = 70

    /// The chosen row if there is one, else the first that can be chosen.
    private var firstFocus: String? {
        items.first(where: { $0.isSelected && $0.isEnabled })?.id
            ?? items.first(where: \.isEnabled)?.id
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    LineupIconTile(symbol: symbol, size: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.inter(30, .bold))
                            .foregroundStyle(LineupStyle.text)
                        if let message, !message.isEmpty {
                            Text(message)
                                .font(.inter(21))
                                .foregroundStyle(LineupPanelStyle.quiet)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    Spacer(minLength: 0)
                }
                .padding(30)
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                    .padding(.horizontal, 30)
                if !items.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(items) { item in
                                row(item, focusedFirst: item.id == firstFocus)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 14)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: min(CGFloat(items.count) * (Self.rowHeight + 6) + 28, 560))
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                        .padding(.horizontal, 30)
                }
                TVSelectable(scale: 1.02, fillRadius: 18, action: cancel,
                             requestInitialFocus: firstFocus == nil) {
                    Text(cancelTitle)
                        .font(.inter(24, .bold))
                        .foregroundStyle(LineupStyle.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.rowHeight)
                }
                .padding(14)
            }
            .frame(width: 860)
            .background(LineupPanelStyle.fill, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
            .focusSection()
        }
        .onExitCommand(perform: cancel)
    }

    private func row(_ item: TVChoice, focusedFirst: Bool) -> some View {
        TVSelectable(scale: 1.02, fillRadius: 18, action: { choose(item) },
                     requestInitialFocus: focusedFirst) {
            HStack(spacing: 18) {
                if let logo = item.logo {
                    PlaybackEngineLogo(asset: logo, size: 42)
                } else if let symbol = item.symbol {
                    LineupIconTile(symbol: symbol, size: 42)
                }
                Text(item.title)
                    .font(.inter(24, .semibold))
                    .foregroundStyle(item.isDestructive ? LineupIconTile.red : LineupStyle.text)
                    .lineLimit(2)
                Spacer(minLength: 12)
                if item.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(LineupStyle.highlight)
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: Self.rowHeight)
            .background(item.isSelected ? LineupPanelStyle.well : .clear,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }
}
#endif
