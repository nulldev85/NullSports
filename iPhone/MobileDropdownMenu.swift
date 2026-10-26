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
    /// Original-color integration artwork, fitted to the same icon slot.
    var imageName: String?
    var isSelected = false
    var isEnabled = true
    var isDestructive = false
    /// The title names playback engines, each led by its logo.
    var namesEngine = false
    /// Opens in the same panel, in place of the list it is in, with the way
    /// back in its header.
    var children: [MobileMenuSection]?
    /// Optional secondary choices, using the same hold sheet as channel rows.
    var holdItems: [MobileMenuItem] = []
    var badge: String? = nil
    var action: () -> Void = {}

    init(_ title: String, symbol: String? = nil, imageName: String? = nil, id: String? = nil,
         isSelected: Bool = false, isEnabled: Bool = true, isDestructive: Bool = false, namesEngine: Bool = false,
         children: [MobileMenuSection]? = nil, action: @escaping () -> Void = {}) {
        self.id = id ?? title
        self.title = title
        self.symbol = symbol
        self.imageName = imageName
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.namesEngine = namesEngine
        self.children = children
        self.action = action
    }
}

/// Rows that belong together, with a hairline between one group and the next.
struct MobileMenuSection: Identifiable {
    let id: String
    let title: String?
    let items: [MobileMenuItem]

    init(id: String, title: String? = nil, items: [MobileMenuItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// The app's dropdown, in place of the system's menu: a panel like every
/// other one -- its header and hairline inside it, then rows with coloured
/// tiles, the chosen one ticked in the accent on the panel's grey well. The
/// Sports tab's league list is drawn the same way, and both on the menus'
/// see-through surface.
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
            + CGFloat(list.filter { $0.title != nil }.count) * 23
        VStack(spacing: 0) {
            header
                .padding(.horizontal, LineupPanelStyle.inset)
                .frame(height: Self.headerHeight - 1)
            Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1)
                .padding(.horizontal, LineupPanelStyle.inset)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, section in
                        if index > 0 {
                            Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            if let title = section.title {
                                Text(title)
                                    .font(.inter(12, .semibold))
                                    .foregroundStyle(LineupPresentationStyle.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 2)
                                    .padding(.bottom, 4)
                            }
                            ForEach(section.items) { item in
                                row(item)
                                    .opacity(shown ? 1 : 0)
                                    .offset(y: shown || reduceMotion ? 0 : -6)
                            }
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
        .mobileMenuSurface(shape)
        .lineupPresentation()
        .shadow(color: .black.opacity(MobileMenuGlass.shadow), radius: 24, y: 12)
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
                    LineupPresentationHeading(title: opened.title, symbol: opened.symbol ?? symbol, compact: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(title)")
        } else {
            LineupPresentationHeading(title: title, symbol: symbol, compact: true)
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
    @Environment(\.lineupPresentationTint) private var presentationTint
    let item: MobileMenuItem
    let select: () -> Void

    var body: some View {
        control
            .disabled(!item.isEnabled)
            .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var control: some View {
        if item.holdItems.isEmpty {
            Button(action: select) { label }
                .buttonStyle(MobileDropdownRowStyle())
        } else {
            label
                .lineupHoldMenu(item.title, symbol: item.symbol ?? "square.stack", press: .well,
                                items: { item.holdItems }, action: select)
                .accessibilityHint("Touch and hold for category options")
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            if let imageName = item.imageName {
                Image(imageName).renderingMode(.original).resizable().scaledToFit()
                    .frame(width: 28, height: 28).accessibilityHidden(true)
            } else if let symbol = item.symbol {
                LineupIconTile(symbol: symbol, size: 28)
            }
            (item.namesEngine ? PlaybackEngineMark.text(item.title, pointSize: 16) : Text(item.title))
                .font(.inter(16, .bold))
                .foregroundStyle(item.isDestructive ? LineupPresentationStyle.destructive : LineupPresentationStyle.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            if let badge = item.badge {
                Text(badge)
                    .font(.inter(11, .semibold))
                    .foregroundStyle(presentationTint ?? LineupStyle.highlight)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(MobileMenuGlass.well, in: Capsule())
            }
            if item.isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(presentationTint ?? LineupStyle.highlight)
            }
            if item.children != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: MobileDropdownPanel.rowHeight)
        .background(item.isSelected ? LineupPresentationStyle.selection(presentationTint ?? LineupStyle.highlight)
                    : MobileMenuGlass.well,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous).inset(by: 2))
        .contentShape(Rectangle())
        .opacity(item.isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .combine)
    }
}

/// A dropdown below its top-bar control. It can sit at either corner or under
/// a centered selector, with the screen stepping back behind the panel. A tap
/// outside closes it, as the button does.
struct MobileDropdownLayer: View {
    let isPresented: Bool
    let title: String
    let symbol: String
    let sections: [MobileMenuSection]
    var alignment: Alignment = .topTrailing
    var horizontalInset: CGFloat = 16
    var backdropOpacity: Double = MobileMenuGlass.backdrop
    var transitionAnchor: UnitPoint = .topTrailing
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: alignment) {
                if isPresented {
                    Color.black.opacity(backdropOpacity)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: close)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    MobileDropdownPanel(title: title, symbol: symbol, sections: sections,
                                        maxHeight: proxy.size.height - 24, dismiss: close)
                        .frame(width: min(300, proxy.size.width - 32))
                        .padding(.horizontal, horizontalInset)
                        .padding(.top, 6)
                        // Opens with a little growth from the button; closes
                        // fading out. Not a compositing group: drawn apart
                        // from the screen, the frost would have nothing
                        // behind it to see.
                        .transition(.asymmetric(
                            insertion: reduceMotion ? AnyTransition.opacity
                                : AnyTransition.scale(scale: 0.94, anchor: transitionAnchor).combined(with: .opacity),
                            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.14))))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
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
                .foregroundStyle(LineupPresentationStyle.text)
                .frame(width: 36, height: 36)
                .background(isOpen ? LineupPresentationStyle.row : LineupPresentationStyle.card, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(isOpen ? "Closes the list" : "Shows the list")
    }
}

/// A row pressed in: a well a step lighter, and a little give.
private struct MobileDropdownRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? MobileMenuGlass.pressed : .clear,
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
                       tint: Color? = nil,
                       items: @escaping () -> [MobileMenuItem],
                       onCancel: @escaping () -> Void = {}) -> some View {
        modifier(MobileChoiceSheet(isPresented: isPresented, title: title, symbol: symbol,
                                   message: message, cancelTitle: cancelTitle, tint: tint,
                                   items: items, onCancel: onCancel))
    }
}

private struct MobileChoiceSheet: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let symbol: String
    let message: String?
    let cancelTitle: String
    let tint: Color?
    let items: () -> [MobileMenuItem]
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowsHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .bottom) {
                if isPresented {
                    Color.black.opacity(MobileMenuGlass.sheetBackdrop)
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
                LineupPresentationHeading(title: title, symbol: symbol, detail: message)
                .padding(LineupPanelStyle.inset)
                if !list.isEmpty {
                    Rectangle().fill(LineupPresentationStyle.divider).frame(height: 1)
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
            .mobileMenuSurface(shape)
            Button { cancel() } label: {
                Text(cancelTitle)
                    .font(.inter(17, .bold))
                    .foregroundStyle(LineupPresentationStyle.text)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .mobileMenuSurface(shape)
                    .contentShape(shape)
            }
            .buttonStyle(MobileDropdownRowStyle())
        }
        .fixedSize(horizontal: false, vertical: true)
        .lineupPresentation(tint: tint)
        .shadow(color: .black.opacity(MobileMenuGlass.shadow), radius: 24, y: 12)
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

// MARK: - The menus' surface

/// What every dropdown, sub-menu, choice sheet and hold menu is drawn on: the
/// panel's grey let partly through, over a frost of the screen behind it. The
/// screen shows softly under the menu, and the frost keeps whatever is there
/// from crossing the rows' words, so they read as plainly as on solid grey.
enum MobileMenuGlass {
    /// How much of the panel's own grey stays over the frost.
    static let tint = LineupPresentationStyle.card.opacity(0.55)
    /// A row's well, as see-through as the panel it sits on.
    static let well = Color.white.opacity(0.055)
    static let pressed = Color.white.opacity(0.09)
    static let edge = Color.white.opacity(0.11)
    /// Lighter than a solid panel's: a dark smear under the glass would show
    /// through it.
    static let shadow = 0.35
    /// The screen steps back a little less than it did behind a solid panel,
    /// or there would be nothing left to see through the glass.
    static let backdrop = 0.32
    static let sheetBackdrop = 0.48
}

extension View {
    /// The menus' see-through panel, in the menu's own shape.
    func mobileMenuSurface<S: InsettableShape>(_ shape: S) -> some View {
        background(MobileMenuGlass.tint, in: shape)
            .background(.ultraThinMaterial, in: shape)
            .environment(\.colorScheme, .dark)
            .overlay(shape.strokeBorder(MobileMenuGlass.edge, lineWidth: 1))
            .clipShape(shape)
    }
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
        var tint: Color? = nil
        var items: [MobileMenuItem]
    }

    @Published var request: Request?

    func present(_ title: String, symbol: String, message: String?, tint: Color? = nil, items: [MobileMenuItem]) {
        guard !items.isEmpty else { return }
        request = Request(title: title, symbol: symbol, message: message, tint: tint, items: items)
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
                        tint: Color? = nil,
                        press: MobileHoldPress = .scale,
                        items: @escaping () -> [MobileMenuItem],
                        onPresent: ((MobileHoldMenu) -> Void)? = nil,
                        action: @escaping () -> Void) -> some View {
        modifier(MobileHoldButton(title: title, symbol: symbol, message: message,
                                  tint: tint, press: press, items: items, onPresent: onPresent, action: action))
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
                           message: menu.request?.message, tint: menu.request?.tint) {
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
    let tint: Color?
    let press: MobileHoldPress
    let items: () -> [MobileMenuItem]
    let onPresent: ((MobileHoldMenu) -> Void)?
    let action: () -> Void

    @Environment(\.mobileHoldMenu) private var menu
    @State private var pressing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(press == .well && pressing ? LineupPresentationStyle.row : Color.clear)
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
        menu.present(title, symbol: symbol, message: message, tint: tint, items: list)
        onPresent?(menu)
    }
}
