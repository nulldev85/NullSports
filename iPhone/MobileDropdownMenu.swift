import SwiftUI

/// One thing a dropdown offers: a tile, its name, and either what it does or
/// a list of its own to go into.
struct MobileMenuItem: Identifiable {
    let id: String
    let title: String
    /// The row's coloured tile. Nil for a plain choice in a long list, such
    /// as a channel category or a season, where a tile on every row would
    /// say nothing.
    var symbol: String?
    var isSelected = false
    var isEnabled = true
    var isDestructive = false
    /// Opens in the same panel, in place of the list it is in, with the way
    /// back in its header.
    var children: [MobileMenuSection]?
    var action: () -> Void = {}

    init(_ title: String, symbol: String? = nil, id: String? = nil,
         isSelected: Bool = false, isEnabled: Bool = true, isDestructive: Bool = false,
         children: [MobileMenuSection]? = nil, action: @escaping () -> Void = {}) {
        self.id = id ?? title
        self.title = title
        self.symbol = symbol
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.children = children
        self.action = action
    }
}

/// Rows that belong together, with a hairline between one group and the next.
struct MobileMenuSection: Identifiable {
    let id: String
    let items: [MobileMenuItem]
}

/// The app's dropdown, in place of the system's menu: a panel like every
/// other one -- its header and hairline inside it, then rows with coloured
/// tiles, the chosen one ticked in the accent on the panel's grey well. The
/// Sports tab's league list is drawn the same way.
struct MobileDropdownPanel: View {
    let title: String
    let symbol: String
    let sections: [MobileMenuSection]
    /// The room it has; past it the list scrolls.
    let maxHeight: CGFloat
    /// Called before a row's own action, so the panel is gone by the time a
    /// sheet that action opens comes up.
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row whose own list is showing, if one is.
    @State private var openedID: String?
    @State private var shown = false

    static let rowHeight: CGFloat = 50
    private static let headerHeight: CGFloat = 46
    private static let inset: CGFloat = 8
    /// A hairline between groups, with the room around it.
    private static let rule: CGFloat = 9

    private var opened: MobileMenuItem? {
        guard let openedID else { return nil }
        return sections.flatMap(\.items).first { $0.id == openedID }
    }

    private var shownSections: [MobileMenuSection] { opened?.children ?? sections }

    var body: some View {
        let shape = LineupPanelStyle.shape
        let list = shownSections
        let rows = list.reduce(0) { $0 + $1.items.count }
        let content = CGFloat(rows) * Self.rowHeight
            + CGFloat(max(0, list.count - 1)) * Self.rule + Self.inset * 2
        VStack(spacing: 0) {
            header
                .padding(.horizontal, LineupPanelStyle.inset)
                .frame(height: Self.headerHeight - 1)
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                .padding(.horizontal, LineupPanelStyle.inset)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, section in
                        if index > 0 {
                            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                        }
                        ForEach(section.items) { item in
                            row(item)
                                .opacity(shown ? 1 : 0)
                                .offset(y: shown || reduceMotion ? 0 : -6)
                        }
                    }
                }
                .padding(Self.inset)
                // A list gone into starts at its top, not where its parent
                // was scrolled to.
                .id(openedID ?? "")
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .frame(height: min(content, max(Self.rowHeight * 2, maxHeight - Self.headerHeight)))
        }
        .background(LineupPanelStyle.fill, in: shape)
        // It floats over panels of its own colour, so it takes a hairline of
        // light round its edge and a deep shadow under it.
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                          : .spring(response: 0.32, dampingFraction: 0.88)) { shown = true }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
    }

    @ViewBuilder
    private var header: some View {
        if let opened {
            Button {
                withAnimation(.snappy(duration: 0.22)) { openedID = nil }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(LineupStyle.highlight)
                    LineupPanelHeader(opened.title, systemImage: opened.symbol)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(title)")
        } else {
            LineupPanelHeader(title, systemImage: symbol)
        }
    }

    private func row(_ item: MobileMenuItem) -> some View {
        MobileMenuRow(item: item) {
            if item.children != nil {
                withAnimation(.snappy(duration: 0.22)) { openedID = item.id }
            } else {
                dismiss()
                item.action()
            }
        }
    }
}

/// One row of a dropdown or a choice sheet: its tile, its name, the accent's
/// tick on the panel's grey well when it is the one chosen.
struct MobileMenuRow: View {
    let item: MobileMenuItem
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                if let symbol = item.symbol {
                    LineupIconTile(symbol: symbol, size: 28)
                }
                Text(item.title)
                    .font(.inter(16, .semibold))
                    .foregroundStyle(item.isDestructive ? LineupIconTile.red : LineupStyle.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                if item.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(LineupStyle.highlight)
                }
                if item.children != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(LineupPanelStyle.quiet)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: MobileDropdownPanel.rowHeight)
            .background(item.isSelected ? LineupPanelStyle.well : .clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .opacity(item.isEnabled ? 1 : 0.4)
        }
        .buttonStyle(MobileDropdownRowStyle())
        .disabled(!item.isEnabled)
        .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The dropdown hung under the bar button that opens it, at the screen's top
/// trailing corner, with everything under it stepping back. A tap outside
/// closes it, as the button does.
struct MobileDropdownLayer: View {
    let isPresented: Bool
    let title: String
    let symbol: String
    let sections: [MobileMenuSection]
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if isPresented {
                    Color.black.opacity(0.45)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: close)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    MobileDropdownPanel(title: title, symbol: symbol, sections: sections,
                                        maxHeight: proxy.size.height - 24, dismiss: close)
                        .frame(width: min(300, proxy.size.width - 32))
                        .padding(.trailing, 16)
                        .padding(.top, 6)
                        // Opens with a little growth from the button; closes
                        // as one flat layer fading out at once.
                        .compositingGroup()
                        .transition(.asymmetric(
                            insertion: reduceMotion ? AnyTransition.opacity
                                : AnyTransition.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity),
                            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.14))))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .allowsHitTesting(isPresented)
    }
}

/// The bar button that opens a dropdown: the reference app's round button --
/// the card grey, a hairline of light, a white ellipsis -- a step lighter
/// while its list is open.
struct MobileDropdownButton: View {
    let isOpen: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(LineupStyle.text)
                .frame(width: 36, height: 36)
                .background(isOpen ? LineupPanelStyle.well : LineupPanelStyle.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(isOpen ? "Closes the list" : "Shows the list")
    }
}

/// A row pressed in: the grey of a chosen row, and a little give.
private struct MobileDropdownRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LineupPanelStyle.well.opacity(0.8) : .clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

extension View {
    /// The app's own sheet of choices, in place of the system's action sheet
    /// and alert, which draw in the system's glass and its type: a panel
    /// that rises from the foot of the screen with a tile, the question and
    /// what it means, a row a choice, and Cancel on its own beneath.
    func lineupChoices(_ title: String, symbol: String, isPresented: Binding<Bool>,
                       message: String? = nil, cancelTitle: String = "Cancel",
                       items: @escaping () -> [MobileMenuItem],
                       onCancel: @escaping () -> Void = {}) -> some View {
        modifier(MobileChoiceSheet(isPresented: isPresented, title: title, symbol: symbol,
                                   message: message, cancelTitle: cancelTitle,
                                   items: items, onCancel: onCancel))
    }
}

private struct MobileChoiceSheet: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let symbol: String
    let message: String?
    let cancelTitle: String
    let items: () -> [MobileMenuItem]
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowsHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .bottom) {
                if isPresented {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { cancel() }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    sheet
                        .frame(maxWidth: 440)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .transition(reduceMotion ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15)
                       : .spring(response: 0.34, dampingFraction: 0.88), value: isPresented)
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { rowsHeight = 0 }
        }
    }

    private var sheet: some View {
        let shape = LineupPanelStyle.shape
        let list = items()
        return VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    LineupIconTile(symbol: symbol, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.inter(17, .bold))
                            .foregroundStyle(LineupStyle.text)
                        if let message {
                            Text(message)
                                .font(.inter(14))
                                .foregroundStyle(LineupPanelStyle.quiet)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                    Spacer(minLength: 0)
                }
                .padding(LineupPanelStyle.inset)
                if !list.isEmpty {
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                        .padding(.horizontal, LineupPanelStyle.inset)
                    // Measure the rows at their actual width so wrapped text
                    // gets its room without stretching a short menu to 380pt.
                    ScrollView {
                        rows(list)
                            .fixedSize(horizontal: false, vertical: true)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: MobileChoiceRowsHeight.self,
                                                           value: proxy.size.height)
                                }
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                    .frame(height: min(rowsHeight > 0 ? rowsHeight
                                       : CGFloat(list.count) * MobileDropdownPanel.rowHeight + 16, 380))
                    .onPreferenceChange(MobileChoiceRowsHeight.self) { rowsHeight = $0 }
                }
            }
            .background(LineupPanelStyle.fill, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(shape)
            Button { cancel() } label: {
                Text(cancelTitle)
                    .font(.inter(17, .bold))
                    .foregroundStyle(LineupStyle.text)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(LineupPanelStyle.fill, in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .contentShape(shape)
            }
            .buttonStyle(MobileDropdownRowStyle())
        }
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { cancel() }
    }

    private func rows(_ list: [MobileMenuItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { item in
                MobileMenuRow(item: item) {
                    isPresented = false
                    item.action()
                }
            }
        }
        .padding(8)
    }

    private func cancel() {
        isPresented = false
        onCancel()
    }
}

private struct MobileChoiceRowsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Touch and hold

/// What a touch held on a card or a row has asked to show, for the screen
/// that hosts it to raise over everything.
final class MobileHoldMenu: ObservableObject {
    struct Request {
        let id = UUID()
        let title: String
        let symbol: String
        let message: String?
        var items: [MobileMenuItem]
    }

    @Published var request: Request?

    func present(_ title: String, symbol: String, message: String?, items: [MobileMenuItem]) {
        guard !items.isEmpty else { return }
        request = Request(title: title, symbol: symbol, message: message, items: items)
    }

    /// An asynchronous capability lookup belongs to the menu that opened it.
    /// Closing it or holding another card must retire that lookup's UI update.
    func updateItems(_ items: [MobileMenuItem], requestID: UUID) {
        guard request?.id == requestID else { return }
        request?.items = items
    }
}

private struct MobileHoldMenuKey: EnvironmentKey {
    static let defaultValue: MobileHoldMenu? = nil
}

extension EnvironmentValues {
    var mobileHoldMenu: MobileHoldMenu? {
        get { self[MobileHoldMenuKey.self] }
        set { self[MobileHoldMenuKey.self] = newValue }
    }
}

/// How a held card shows it is being pressed.
enum MobileHoldPress {
    /// A little give, as an artwork card has.
    case scale
    /// The panel's grey well behind it, as a row in a panel has.
    case well
    /// Dimmed a little, for something on a ground of its own that must keep
    /// its size, as the Guide's frozen channel column does.
    case dim
}

extension View {
    /// Where the touch-and-hold choices of everything inside rise: over all
    /// of it, tab bar and all.
    func lineupHoldMenuHost() -> some View {
        modifier(MobileHoldMenuHost())
    }

    /// A tap does `action`; a touch held a moment lifts the app's own sheet
    /// of `items`, in place of the system's context menu, which draws in
    /// its own glass and type.
    func lineupHoldMenu(_ title: String, symbol: String, message: String? = nil,
                        press: MobileHoldPress = .scale,
                        items: @escaping () -> [MobileMenuItem],
                        onPresent: ((MobileHoldMenu) -> Void)? = nil,
                        action: @escaping () -> Void) -> some View {
        modifier(MobileHoldButton(title: title, symbol: symbol, message: message,
                                  press: press, items: items, onPresent: onPresent, action: action))
    }
}

private struct MobileHoldMenuHost: ViewModifier {
    @StateObject private var menu = MobileHoldMenu()

    func body(content: Content) -> some View {
        content
            .environment(\.mobileHoldMenu, menu)
            .lineupChoices(menu.request?.title ?? "", symbol: menu.request?.symbol ?? "ellipsis",
                           isPresented: Binding(get: { menu.request != nil },
                                                set: { if !$0 { menu.request = nil } }),
                           message: menu.request?.message) {
                menu.request?.items ?? []
            }
    }
}

/// A tap and a held touch told apart the way the system tells them apart:
/// the tap only if the finger lifts before the hold is reached, the choices
/// only once it is, and neither once the finger has moved to scroll.
private struct MobileHoldButton: ViewModifier {
    let title: String
    let symbol: String
    let message: String?
    let press: MobileHoldPress
    let items: () -> [MobileMenuItem]
    let onPresent: ((MobileHoldMenu) -> Void)?
    let action: () -> Void

    @Environment(\.mobileHoldMenu) private var menu
    @State private var pressing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(press == .well && pressing ? LineupPanelStyle.well : Color.clear)
            .scaleEffect(press == .scale && pressing ? 0.97 : 1)
            .opacity(press == .dim && pressing ? 0.6 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: pressing)
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.4, perform: open,
                                onPressingChanged: { pressing = $0 })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityAction(named: Text("More")) { open() }
    }

    private func open() {
        let list = items()
        guard !list.isEmpty, let menu else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        menu.present(title, symbol: symbol, message: message, items: list)
        onPresent?(menu)
    }
}
