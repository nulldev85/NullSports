import SwiftUI

/// App-owned presentations share the Guide's near-black ground, subdued
/// rounded type and deep tinted rows. iOS pages use these same neutral tokens;
/// playback chrome keeps its contrast and tvOS retains its approved surfaces.
enum LineupPresentationStyle {
    static let ground = Color(red: 0.025, green: 0.028, blue: 0.032)
    static let card = Color(red: 0.067, green: 0.073, blue: 0.082)
    static let row = Color(red: 0.090, green: 0.098, blue: 0.110)
    static let text = Color.white.opacity(0.82)
    static let secondary = Color.white.opacity(0.49)
    static let divider = Color.white.opacity(0.065)
    static let border = Color.white.opacity(0.075)
    static let destructive = Color(red: 0.96, green: 0.31, blue: 0.35)
    static func selection(_ tint: Color) -> Color { tint.opacity(0.17) }
}

private struct LineupIsPresentationKey: EnvironmentKey { static let defaultValue = false }
private struct LineupPresentationTintKey: EnvironmentKey { static let defaultValue: Color? = nil }

extension EnvironmentValues {
    var lineupIsPresentation: Bool {
        get { self[LineupIsPresentationKey.self] }
        set { self[LineupIsPresentationKey.self] = newValue }
    }
    var lineupPresentationTint: Color? {
        get { self[LineupPresentationTintKey.self] }
        set { self[LineupPresentationTintKey.self] = newValue }
    }
}

struct LineupPresentationHeading: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var compact = false

    private var titleSize: CGFloat {
        #if os(tvOS)
        compact ? 24 : 30
        #else
        compact ? 16 : 19
        #endif
    }
    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: compact ? 10 : 14) {
            LineupIconTile(symbol: symbol, size: titleSize * (compact ? 1.65 : 1.9))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.inter(titleSize, .heavy))
                    .foregroundStyle(LineupPresentationStyle.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.inter(titleSize * 0.73, .medium))
                        .foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LineupPresentationScope: ViewModifier {
    @Environment(\.lineupPresentationTint) private var inheritedTint
    let tint: Color?
    func body(content: Content) -> some View {
        content.environment(\.lineupIsPresentation, true)
            .environment(\.lineupPresentationTint, tint ?? inheritedTint)
            .foregroundStyle(LineupPresentationStyle.text)
            .tint(tint ?? inheritedTint ?? LineupStyle.highlight)
            .preferredColorScheme(.dark)
    }
}

struct LineupScopedSurface: ViewModifier {
    @Environment(\.lineupIsPresentation) private var presentation
    let clear: Bool
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background(presentation ? LineupPresentationStyle.card : LineupStyle.surface.opacity(clear ? 0.72 : 0.94), in: shape)
            .overlay(shape.strokeBorder(presentation ? LineupPresentationStyle.border : LineupStyle.line, lineWidth: 1))
    }
}

extension View {
    func lineupPresentation(tint: Color? = nil) -> some View {
        modifier(LineupPresentationScope(tint: tint))
    }

    func lineupPresentationSurface<S: InsettableShape>(_ shape: S) -> some View {
        background(LineupPresentationStyle.card, in: shape)
            .overlay(shape.strokeBorder(LineupPresentationStyle.border, lineWidth: 1))
            .clipShape(shape)
    }

    func lineupSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                 @ViewBuilder content: @escaping () -> Sheet) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().lineupPresentation()
                .presentationBackground(LineupPresentationStyle.ground)
        }
    }

    func lineupSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                 @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        sheet(item: item, onDismiss: onDismiss) { value in
            content(value).lineupPresentation()
                .presentationBackground(LineupPresentationStyle.ground)
        }
    }

    func lineupFullScreenCover<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                 @ViewBuilder content: @escaping () -> Sheet) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { content().lineupPresentation() }
    }

    func lineupFullScreenCover<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                 @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { value in content(value).lineupPresentation() }
    }

    func lineupMessage(_ title: String, symbol: String, isPresented: Binding<Bool>, message: String,
                       onDismiss: @escaping () -> Void = {}) -> some View {
        #if os(tvOS)
        tvChoices(title, symbol: symbol, isPresented: isPresented, message: message, cancelTitle: "OK", items: { [] }, onCancel: onDismiss)
        #else
        lineupChoices(title, symbol: symbol, isPresented: isPresented, message: message, cancelTitle: "OK", items: { [] }, onCancel: onDismiss)
        #endif
    }
}

#if os(iOS)
extension View {
    func lineupTextPrompt(_ title: String, symbol: String, isPresented: Binding<Bool>, text: Binding<String>,
                          prompt: String, message: String? = nil, saveTitle: String = "Save", canSave: Bool,
                          onSave: @escaping () -> Void, onCancel: @escaping () -> Void = {}) -> some View {
        modifier(LineupTextPromptModifier(title: title, symbol: symbol, isPresented: isPresented, text: text,
            prompt: prompt, message: message, saveTitle: saveTitle, canSave: canSave, onSave: onSave, onCancel: onCancel))
    }
}

private struct LineupTextPromptModifier: ViewModifier {
    let title: String
    let symbol: String
    @Binding var isPresented: Bool
    @Binding var text: String
    let prompt: String
    let message: String?
    let saveTitle: String
    let canSave: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @State private var saved = false

    func body(content: Content) -> some View {
        content.lineupSheet(isPresented: $isPresented, onDismiss: {
            if !saved { onCancel() }
            saved = false
        }) {
            LineupTextPrompt(title: title, symbol: symbol, text: $text, prompt: prompt, message: message,
                saveTitle: saveTitle, canSave: canSave, save: {
                    guard !saved else { return }
                    saved = true
                    onSave()
                    isPresented = false
                }, cancel: { isPresented = false })
        }
    }
}

private struct LineupTextPrompt: View {
    let title: String
    let symbol: String
    @Binding var text: String
    let prompt: String
    let message: String?
    let saveTitle: String
    let canSave: Bool
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                LineupPresentationHeading(title: title, symbol: symbol, detail: message)
                TextField(text: $text, prompt: Text(prompt).foregroundStyle(LineupPresentationStyle.secondary)) { Text(prompt) }
                    .textFieldStyle(.plain).font(.inter(.body, .bold)).focused($focused).submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                    .padding(16).frame(minHeight: 54)
                    .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel(prompt)
                HStack(spacing: 10) {
                    Button("Cancel", action: cancel).buttonStyle(LineupPromptButtonStyle(prominent: false))
                    Button(saveTitle, action: save).buttonStyle(LineupPromptButtonStyle(prominent: true)).disabled(!canSave)
                }
            }.padding(22)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(message == nil ? 268 : 330), .large])
        .presentationDragIndicator(.visible)
        .task { focused = true }
    }
}

private struct LineupPromptButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.inter(.body, .heavy))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(LineupPresentationStyle.text)
            .background(prominent ? LineupPresentationStyle.selection(LineupStyle.highlight) : LineupPresentationStyle.row,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.35)
    }
}
#endif
