import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// Adding a media server: its kind chosen by logo, and that kind's own way
/// in beside it.
///
/// Choosing is moving. On the television, the server whose logo has focus is
/// the one being added, and its sign-in is already there below it; on the
/// phone, the sign-ins sit side by side and a swipe moves between them as a
/// tap on a logo does.
///
/// All four sign-ins are built once, when the screen opens, and are only
/// ever shown and hidden after that. Building one afresh on every move, text
/// fields and all, is what made moving between them stutter.
struct MediaServerSetupView: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @State private var software: MediaServerBrand = .jellyfin
    /// What has been typed for each kind, kept apart, so moving across to
    /// look at another does not carry one server's address into another's.
    @State private var forms: [MediaServerBrand: MediaServerSignIn] = [:]
    #if !os(tvOS)
    @State private var page: MediaServerBrand? = .jellyfin
    /// Held, not observed: a swipe moves the marker under the logos on every
    /// frame, and only the logos should redraw for it.
    @State private var swipe = MediaServerSwipe()
    #endif

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                PageTitle(eyebrow: "Settings", title: "Add Media Server",
                          detail: "Move across to your server. Its sign-in follows.")
                MediaServerPicker(selection: choice)
                // Laid over one another at one height, so the page never
                // shifts as they change; the one shown fades and slides in
                // from the side its logo is on.
                MediaServerPanelStack {
                    ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                        let shown = brand == software
                        panel(for: brand)
                            .opacity(shown ? 1 : 0)
                            .offset(x: shown ? 0 : (order(of: brand) < order(of: software) ? -36 : 36))
                            // A hidden sign-in never takes focus.
                            .disabled(!shown)
                            .accessibilityHidden(!shown)
                    }
                }
                // Down from any logo lands here, the Plex one at the far
                // right included, whatever sits directly beneath it.
                .focusSection()
                if let error = media.errorMessage {
                    Text(error).font(.inter(.callout)).foregroundStyle(LineupStyle.live)
                }
                // A television draws no navigation bar, so this screen's way
                // out is a button of its own.
                Button("Cancel", role: .cancel) { dismiss() }
                    .lineupButtonStyle()
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 56)
        }
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .disabled(media.isAddingServer)
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MediaServerPicker(selection: choice, swipe: swipe)
                        .padding(.horizontal, 16)
                    // The sign-ins side by side, one to a page, all of one
                    // height: a swipe moves between servers as a tap on a
                    // logo does, and the marker under the logos follows the
                    // finger.
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                                panel(for: brand)
                                    .padding(.horizontal, 16)
                                    .containerRelativeFrame(.horizontal)
                            }
                        }
                        .scrollTargetLayout()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $page)
                    .scrollIndicators(.hidden)
                    .modifier(MediaServerPagerTracking(swipe: swipe))
                    if let error = media.errorMessage {
                        Text(error).font(.inter(.footnote)).foregroundStyle(LineupStyle.live)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LineupPresentationStyle.ground)
            .navigationTitle("Add Media Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { LineupToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.buttonStyle(LineupBarButtonStyle()) } }
            .disabled(media.isAddingServer)
            .onChange(of: page) { _, brand in
                guard let brand, brand != software else { return }
                clearError()
                software = brand
                // Without the pager's own position to follow, the marker
                // glides to the page it settled on.
                if #unavailable(iOS 18) {
                    withAnimation(.smooth(duration: 0.3)) { swipe.progress = CGFloat(order(of: brand)) }
                }
            }
        }
        #endif
    }

    /// The server being added, chosen from the logos.
    private var choice: Binding<MediaServerBrand> {
        Binding {
            software
        } set: { brand in
            guard brand != software else { return }
            clearError()
            #if os(tvOS)
            withAnimation(.smooth(duration: 0.3)) { software = brand }
            #else
            software = brand
            withAnimation(.smooth(duration: 0.35)) { page = brand }
            #endif
        }
    }

    /// One server's failure is not news on the next one's sign-in. Only a
    /// message that is there is cleared: every write to the Library, even of
    /// what it already holds, redraws everything that watches it, the whole
    /// Library behind this screen included.
    private func clearError() {
        if media.errorMessage != nil { media.errorMessage = nil }
    }

    private func order(of brand: MediaServerBrand) -> Int {
        MediaServerBrand.allCases.firstIndex(of: brand) ?? 0
    }

    @ViewBuilder private func panel(for brand: MediaServerBrand) -> some View {
        Group {
            if brand == .silo {
                SiloSignInPanel(onAdded: { dismiss() })
            } else if brand == .plex {
                PlexLinkPanel(onAdded: { dismiss() })
            } else {
                MediaServerSignInPanel(brand: brand, form: form(for: brand)) { sign in
                    Task {
                        if await media.addServer(name: sign.name, serverURL: sign.server, username: sign.username,
                                                 password: sign.password, software: brand) { dismiss() }
                    }
                }
            }
        }
        .environment(\.lineupPresentationTint, brand.loginTint)
        .tint(brand.loginTint)
    }

    private func form(for brand: MediaServerBrand) -> Binding<MediaServerSignIn> {
        Binding { forms[brand] ?? MediaServerSignIn() } set: { forms[brand] = $0 }
    }
}

/// What a Jellyfin or Emby sign-in has been given so far.
struct MediaServerSignIn: Equatable {
    var name = ""
    var server = ""
    var username = ""
    var password = ""

    /// A password is not required. Jellyfin and Emby both allow passwordless
    /// users, and some ship that way until an operator sets one.
    var isComplete: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Every sign-in in one place, each given the height of the tallest, so the
/// card stays the same size whichever is shown.
private struct MediaServerPanelStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

#if !os(tvOS)
/// How far across the sign-ins the phone's pager sits, in pages.
@Observable
final class MediaServerSwipe {
    var progress: CGFloat = 0
}

/// Keeps the marker under the logos where the pager is, frame by frame, as a
/// finger or a tap moves it. The pager says where it is itself: a reading
/// taken from inside its pages was never passed on, which left the marker on
/// the first logo.
private struct MediaServerPagerTracking: ViewModifier {
    let swipe: MediaServerSwipe

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                (geometry.contentOffset.x + geometry.contentInsets.leading) / max(geometry.containerSize.width, 1)
            } action: { _, progress in
                swipe.progress = progress
            }
        } else {
            content
        }
    }
}
#endif

/// All server options share one row. On the television the one with
/// focus is the one chosen, so moving across them is choosing.
private struct MediaServerPicker: View {
    @Binding var selection: MediaServerBrand
    #if os(tvOS)
    @FocusState private var focused: MediaServerBrand?
    #else
    let swipe: MediaServerSwipe
    #endif

    var body: some View {
        #if os(tvOS)
        HStack(spacing: gap) {
            ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                let chosen = selection == brand
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                tile(brand, chosen: chosen)
                    .background(chosen ? brand.loginTint.opacity(0.18) : LineupPresentationStyle.row, in: shape)
                    .overlay(shape.strokeBorder(chosen ? LineupPresentationStyle.text.opacity(0.6) : LineupStyle.line,
                                                lineWidth: chosen ? 1.5 : 0.5))
                    .lineupFocusLayer(focused == brand, in: shape.inset(by: -6))
                    .focusable()
                    .focused($focused, equals: brand)
                    .focusEffectDisabled()
                    .onTapGesture { selection = brand }
                    .scaleEffect(focused == brand ? LineupStyle.controlLift : 1)
                    .lineupShadow(.lifted, on: focused == brand)
                    .zIndex(focused == brand ? 1 : 0)
                    .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused == brand)
            }
        }
        // Coming back up from a sign-in returns to the logo it belongs to,
        // not to whichever logo happens to sit above the button just left.
        .defaultFocus($focused, selection, priority: .userInitiated)
        .focusSection()
        .onChange(of: focused) { _, brand in
            if let brand { selection = brand }
        }
        #else
        HStack(spacing: gap) {
            ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                Button { selection = brand } label: { tile(brand, chosen: selection == brand) }
                    .lineupFlatButton()
            }
        }
        .background { marker }
        #endif
    }

    #if !os(tvOS)
    /// The tiles' wells, and the chosen fill gliding across them as the
    /// sign-ins below are swiped.
    private var marker: some View {
        GeometryReader { row in
            let count = CGFloat(MediaServerBrand.allCases.count)
            let width = (row.size.width - gap * (count - 1)) / count
            let position = min(max(swipe.progress, 0), count - 1)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack(alignment: .leading) {
                HStack(spacing: gap) {
                    ForEach(MediaServerBrand.allCases, id: \.self) { _ in
                        shape.fill(LineupPresentationStyle.row)
                            .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 0.5))
                    }
                }
                shape.fill(selection.loginTint.opacity(0.18))
                    .overlay(shape.strokeBorder(LineupPresentationStyle.text.opacity(0.6), lineWidth: 1.5))
                    .frame(width: width)
                    .offset(x: (width + gap) * position)
            }
        }
    }
    #endif

    private func tile(_ brand: MediaServerBrand, chosen: Bool) -> some View {
        VStack(spacing: labelGap) {
            MediaServerLogo(brand: brand).frame(width: logo, height: logo)
            Text(brand.name).font(.inter(labelSize, .semibold))
                .foregroundStyle(chosen ? LineupPresentationStyle.text : LineupPresentationStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, padding)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    #if os(tvOS)
    private var gap: CGFloat { 28 }
    private var logo: CGFloat { 72 }
    private var padding: CGFloat { 26 }
    private var radius: CGFloat { 20 }
    private var labelGap: CGFloat { 12 }
    private var labelSize: CGFloat { 24 }
    #else
    private var gap: CGFloat { 8 }
    private var logo: CGFloat { 32 }
    private var padding: CGFloat { 12 }
    private var radius: CGFloat { 14 }
    private var labelGap: CGFloat { 8 }
    private var labelSize: CGFloat { 13 }
    #endif
}

/// A server's own sign-in, under its logo and name.
struct MediaServerPanel<Content: View>: View {
    let brand: MediaServerBrand
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: headerGap) {
                MediaServerLogo(brand: brand).frame(width: logo, height: logo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.inter(titleSize, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(brand.signInNote).font(.inter(noteSize)).foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(inset)
        // As tall as it is given: beside or behind the other sign-ins, each
        // card takes the tallest one's height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(tvOS)
        .background(brand.loginTint.opacity(0.13), in: shape)
        .background(LineupPresentationStyle.card, in: shape)
        .overlay(shape.strokeBorder(brand.loginTint.opacity(0.24), lineWidth: 0.7))
        #else
        .modifier(MobileBrandPanel(palette: .server(brand)))
        #endif
    }

    #if os(tvOS)
    private var radius: CGFloat { 26 }
    private var spacing: CGFloat { 30 }
    private var headerGap: CGFloat { 20 }
    private var logo: CGFloat { 56 }
    private var titleSize: CGFloat { 32 }
    private var noteSize: CGFloat { 22 }
    private var inset: CGFloat { 36 }
    #else
    private var radius: CGFloat { 18 }
    private var spacing: CGFloat { 18 }
    private var headerGap: CGFloat { 12 }
    private var logo: CGFloat { 36 }
    private var titleSize: CGFloat { 18 }
    private var noteSize: CGFloat { 13 }
    private var inset: CGFloat { 16 }
    #endif
}

/// Jellyfin's or Emby's sign-in: where the server is, and whose account.
private struct MediaServerSignInPanel: View {
    @Environment(MediaLibrary.self) private var media
    let brand: MediaServerBrand
    @Binding var form: MediaServerSignIn
    let connect: (MediaServerSignIn) -> Void

    var body: some View {
        MediaServerPanel(brand: brand, title: "Sign in to \(brand.name)") {
            fields
                // A capitalised host or an autocorrected one is not the
                // address anybody meant to type, and on a television, where
                // every character costs a click, it is not obvious what went
                // wrong either.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                connect(form)
            } label: {
                Text(media.isAddingServer ? "Connecting…" : "Connect")
            }
            .buttonStyle(IntegrationButtonStyle()).focusEffectDisabled()
            .disabled(media.isAddingServer || !form.isComplete)
            Text(footer)
                .font(.inter(footerSize)).foregroundStyle(LineupPresentationStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var fields: some View {
        #if os(tvOS)
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 22) {
            GridRow {
                MediaServerField(label: "Server address", prompt: "192.168.1.50:8096", text: $form.server, kind: .address)
                MediaServerField(label: "Display name", prompt: "Optional", text: $form.name)
            }
            GridRow {
                MediaServerField(label: "Username", prompt: "Username", text: $form.username, kind: .username)
                MediaServerField(label: "Password", prompt: "Optional", text: $form.password, kind: .password)
            }
        }
        #else
        VStack(spacing: 0) {
            MediaServerField(label: "Address", prompt: "192.168.1.50:8096", text: $form.server, kind: .address)
            MediaServerFieldDivider()
            MediaServerField(label: "Name", prompt: "Optional", text: $form.name)
            MediaServerFieldDivider()
            MediaServerField(label: "Username", prompt: "Required", text: $form.username, kind: .username)
            MediaServerFieldDivider()
            MediaServerField(label: "Password", prompt: "Optional", text: $form.password, kind: .password)
        }
        .background(brand.loginTint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #endif
    }

    private var footer: String {
        "The host and port is enough, as the server's web app opens on. Leave the password blank for a user that has none. Sign-ins are kept in this device's Keychain, and every server you add feeds the Library together."
    }

    #if os(tvOS)
    private var footerSize: CGFloat { 20 }
    #else
    private var footerSize: CGFloat { 12 }
    #endif
}

/// One labelled field of a sign-in. Silo's sign-in shares it.
struct MediaServerField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var kind: Kind = .plain

    /// A secret is hidden like a password, but it is not one, so the
    /// device does not offer saved passwords for it.
    enum Kind { case plain, address, username, password, secret }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.inter(20, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
            input
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        HStack(spacing: 12) {
            Text(label).font(.inter(.subheadline)).foregroundStyle(LineupPresentationStyle.secondary)
                .frame(width: 84, alignment: .leading)
            input
                .font(.inter(.subheadline))
                .foregroundStyle(LineupPresentationStyle.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        #endif
    }

    @ViewBuilder private var input: some View {
        switch kind {
        case .password:
            SecureField(label, text: $text, prompt: Text(prompt))
                #if !os(tvOS)
                .textContentType(.password)
                #endif
        case .secret:
            SecureField(label, text: $text, prompt: Text(prompt))
        case .address:
            TextField(label, text: $text, prompt: Text(prompt))
                #if !os(tvOS)
                .keyboardType(.URL)
                .textContentType(.URL)
                #endif
        case .username:
            TextField(label, text: $text, prompt: Text(prompt))
                #if !os(tvOS)
                .textContentType(.username)
                #endif
        case .plain:
            TextField(label, text: $text, prompt: Text(prompt))
        }
    }
}

/// A hairline between two fields of an iPhone sign-in.
struct MediaServerFieldDivider: View {
    var body: some View {
        Divider().overlay(LineupStyle.line).padding(.leading, 14)
    }
}

/// One of a sign-in's choices, such as how to sign in or which profile,
/// marked when it is the one in use.
struct MediaServerChoice: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "checkmark").font(.system(size: checkSize, weight: .heavy))
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .foregroundStyle(LineupPresentationStyle.text)
        }
        #if os(tvOS)
        .buttonStyle(IntegrationButtonStyle()).focusEffectDisabled()
        #else
        .buttonStyle(MobileIntegrationButtonStyle(selected: selected))
        #endif
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    #if os(tvOS)
    private var checkSize: CGFloat { 18 }
    #else
    private var checkSize: CGFloat { 10 }
    #endif
}

/// Linking a Plex account, Plex's own way: a short code entered at
/// plex.tv/link, then the account's servers to choose from.
///
/// No password passes through Lineup. The account's token comes back to the
/// device that asked for the code, and each server's own token with it.
private struct PlexLinkPanel: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.openURL) private var openURL
    let onAdded: () -> Void

    private enum Step {
        case start
        case waiting(code: String)
        case finding
        case choosing([PlexAccount.Server])
        case failed(String)
    }

    @State private var step: Step = .start
    @State private var accountName = "Plex"
    @State private var linking: Task<Void, Never>?

    var body: some View {
        MediaServerPanel(brand: .plex, title: "Link your Plex account") {
            switch step {
            case .start:
                Text("You'll get a short code to enter at plex.tv/link on any phone or computer. Lineup never sees your Plex password.")
                    .font(.inter(bodySize)).foregroundStyle(LineupPresentationStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { link() } label: { actionTitle("Link Plex Account") }
                    .buttonStyle(IntegrationButtonStyle()).focusEffectDisabled()
            case .waiting(let code):
                VStack(alignment: .leading, spacing: 14) {
                    Text("Go to **plex.tv/link** and enter this code:")
                        .font(.inter(bodySize)).foregroundStyle(LineupPresentationStyle.secondary)
                    Text(code)
                        .font(.interDigits(codeSize, .heavy)).tracking(codeSize * 0.22)
                        .foregroundStyle(LineupPresentationStyle.text)
                        .padding(.horizontal, codeSize * 0.6).padding(.vertical, codeSize * 0.3)
                        .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for Plex…").font(.inter(captionSize)).foregroundStyle(LineupPresentationStyle.secondary)
                    }
                }
                #if !os(tvOS)
                Button { openURL(URL(string: "https://plex.tv/link")!) } label: { actionTitle("Open plex.tv/link") }
                    .buttonStyle(IntegrationButtonStyle()).focusEffectDisabled()
                #endif
            case .finding:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding your Plex servers…").font(.inter(bodySize)).foregroundStyle(LineupPresentationStyle.secondary)
                }
            case .choosing(let servers):
                Text("Choose the server to add.")
                    .font(.inter(bodySize)).foregroundStyle(LineupPresentationStyle.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(servers) { server in
                        Button { add(server) } label: {
                            HStack(spacing: 12) {
                                MediaServerLogo(brand: .plex).frame(width: rowLogo, height: rowLogo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).font(.inter(bodySize, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                                    Text(server.owned == false ? "Shared with you" : "Your server")
                                        .font(.inter(captionSize)).foregroundStyle(LineupPresentationStyle.secondary)
                                }
                                #if os(tvOS)
                                Spacer(minLength: 0)
                                #endif
                            }
                        }
                        .buttonStyle(IntegrationButtonStyle()).focusEffectDisabled()
                    }
                }
            case .failed(let message):
                Text(message).font(.inter(bodySize)).foregroundStyle(LineupStyle.live)
                Button { link() } label: { actionTitle("Try Again") }
                    .buttonStyle(IntegrationButtonStyle()).focusEffectDisabled()
            }
        }
        .onDisappear { linking?.cancel() }
    }

    private func actionTitle(_ title: String) -> some View {
        Text(title)
    }

    private func link() {
        linking?.cancel()
        linking = Task { @MainActor in
            do {
                let clientID = media.plexClientID
                let pin = try await PlexAccount.requestPin(clientID: clientID)
                withAnimation(.smooth) { step = .waiting(code: pin.code) }
                // A code lasts about a quarter of an hour. A check that fails
                // on the way is asked again: one dropped request is no reason
                // to send the viewer back for a new code.
                let deadline = Date().addingTimeInterval(15 * 60)
                var token: String?
                while token == nil, Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    token = (try? await PlexAccount.checkPin(pin.id, clientID: clientID))?.authToken
                }
                guard let token else {
                    step = .failed("That code has expired. Get a new one and try again.")
                    return
                }
                withAnimation(.smooth) { step = .finding }
                accountName = (try? await PlexAccount.user(token: token, clientID: clientID))?.displayName ?? "Plex"
                let servers = try await PlexAccount.servers(token: token, clientID: clientID)
                guard !servers.isEmpty else {
                    step = .failed("This Plex account has no servers to add.")
                    return
                }
                // One server is the one meant; several are a choice.
                if servers.count == 1 {
                    add(servers[0])
                } else {
                    withAnimation(.smooth) { step = .choosing(servers) }
                }
            } catch is CancellationError {
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func add(_ server: PlexAccount.Server) {
        Task { @MainActor in
            if await media.addPlexServer(server, accountName: accountName) { onAdded() }
        }
    }

    #if os(tvOS)
    private var bodySize: CGFloat { 24 }
    private var captionSize: CGFloat { 20 }
    private var codeSize: CGFloat { 64 }
    private var rowLogo: CGFloat { 40 }
    #else
    private var bodySize: CGFloat { 15 }
    private var captionSize: CGFloat { 12 }
    private var codeSize: CGFloat { 34 }
    private var rowLogo: CGFloat { 30 }
    #endif
}

struct MDBListIntegrationView: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var disconnecting = false

    var body: some View {
        NavigationStack {
            Form {
                if let account = media.mdbListAccount {
                    Section("Connected Account") {
                        LabeledContent("Account", value: "@\(account.username)")
                        if let plan = account.plan { LabeledContent("Plan", value: plan) }
                        LabeledContent("Catalogs", value: media.mdbListCatalogs.count.formatted())
                        if let remaining = account.requestsRemaining {
                            LabeledContent("API requests left", value: remaining.formatted())
                        }
                    }
                    .listRowBackground(LineupPresentationStyle.row)
                }

                Section {
                    SecureField("MDBList API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(connectTitle) {
                        Task {
                            if await media.connectMDBList(apiKey: apiKey) {
                                apiKey = ""
                                dismiss()
                            }
                        }
                    }
                    .lineupButtonStyle()
                    .disabled(media.isMDBListLoading
                        || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text(media.isMDBListConnected ? "Replace API Key" : "Connect MDBList")
                } footer: {
                    #if os(tvOS)
                    Text("Create or copy a free API key from MDBList Preferences. Lineup stores it securely in this device’s Keychain. Your MDBList lists then appear in Settings › Library › Add Shelf.")
                    #else
                    Text("Create or copy a free API key from MDBList Preferences. Lineup stores it securely in this device’s Keychain. Your MDBList lists then appear in Library → Add Shelf.")
                    #endif
                }
                .listRowBackground(LineupPresentationStyle.row)

                Section {
                    Link("Open MDBList Preferences", destination: URL(string: "https://mdblist.com/preferences/")!)
                    if media.isMDBListConnected {
                        Button("Disconnect MDBList", role: .destructive) { disconnecting = true }
                            .lineupButtonStyle()
                    }
                }
                .listRowBackground(LineupPresentationStyle.row)

                #if os(tvOS)
                Section {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .lineupButtonStyle()
                }
                #endif

                if let error = media.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .background(LineupPresentationStyle.ground)
            .navigationTitle("MDBList")
            #if !os(tvOS)
            .toolbar { LineupToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.buttonStyle(LineupBarButtonStyle()) } }
            #endif
            #if os(tvOS)
            .tvChoices("Disconnect MDBList?", symbol: "list.star", isPresented: $disconnecting,
                       message: "MDBList shelves will be removed. Your lists on MDBList will not be changed.") {
                [TVChoice("Disconnect", isDestructive: true) {
                    media.disconnectMDBList()
                    dismiss()
                }]
            }
            #else
            .lineupChoices("Disconnect MDBList?", symbol: "list.star", isPresented: $disconnecting,
                           message: "MDBList shelves will be removed. Your lists on MDBList will not be changed.") {
                [MobileMenuItem("Disconnect", isDestructive: true) {
                    media.disconnectMDBList()
                    dismiss()
                }]
            }
            #endif
        }
    }

    private var connectTitle: String {
        if media.isMDBListLoading { return "Connecting…" }
        return media.isMDBListConnected ? "Save New Key" : "Connect"
    }
}

struct InitialSourceSetupView: View {
    @State private var addingIPTV = false
    @State private var addingMedia = false
    #if os(tvOS)
    @State private var settingUpFromPhone = false
    #endif

    var body: some View {
        VStack(spacing: 30) {
            PageTitle(eyebrow: "LINEUP", title: "Bring your streams together.",
                detail: "Connect live television, your own media library, or both.")
            #if os(tvOS)
            HStack(spacing: 24) {
                Button { addingIPTV = true } label: {
                    Label("Add IPTV Provider", systemImage: "dot.radiowaves.left.and.right")
                }
                Button { addingMedia = true } label: {
                    Label {
                        Text("Add Media Server")
                    } icon: {
                        MediaServerLogoRow(size: 26)
                    }
                }
                Button { settingUpFromPhone = true } label: {
                    Label("Set Up with iPhone", systemImage: "iphone")
                }
            }
            .lineupButtonStyle()
            #else
            VStack(spacing: 14) {
                Button { addingIPTV = true } label: {
                    Label("Add IPTV Provider", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                Button { addingMedia = true } label: {
                    Label {
                        Text("Add Media Server")
                    } icon: {
                        MediaServerLogoRow(size: 18)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .lineupButtonStyle()
            #endif
        }
        .padding(setupPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background)
        .lineupSheet(isPresented: $addingIPTV) {
            #if os(iOS)
            ProfileSetupView(addingProvider: true)
            #else
            ProfileSetupView()
            #endif
        }
        .lineupSheet(isPresented: $addingMedia) { MediaServerSetupView() }
        #if os(tvOS)
        .lineupFullScreenCover(isPresented: $settingUpFromPhone) { TVDeviceSetupView() }
        #endif
    }

    private var setupPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        24
        #endif
    }
}
