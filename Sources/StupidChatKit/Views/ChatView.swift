import SwiftUI
import UIKit

/// The shared chat screen: the UIKit chat full-bleed under a transparent bar, with the title in a floating
/// pill. It connects while visible and again when the app becomes active.
public struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Tapping the title pill, such as to list members; `nil` leaves the pill inert.
    var onTitleTap: (() -> Void)?
    var showProfile: (ChatUser) -> Void
    /// While a screen pushed on top reads the chat's live state, leaving doesn't disconnect.
    var keepsConnection: Bool

    public init(viewModel: ChatViewModel, onTitleTap: (() -> Void)? = nil, showProfile: @escaping (ChatUser) -> Void = { _ in }, keepsConnection: Bool = false) {
        self.viewModel = viewModel
        self.onTitleTap = onTitleTap
        self.showProfile = showProfile
        self.keepsConnection = keepsConnection
    }

    @AppStorage(ChatRedaction.defaultsKey) private var redactionEnabled = false
    @Environment(\.dismiss) private var dismiss

    /// Like the feed, "Redact names" hides people's names: the title of a chat named for people, and an
    /// `@username` subtitle.
    private var displayTitle: String {
        viewModel.titleNamesPeople ? ChatRedaction.name(viewModel.title, enabled: redactionEnabled) : viewModel.title
    }

    private var displaySubtitle: String {
        redactionEnabled && viewModel.subtitle.hasPrefix("@") ? "Redacted" : viewModel.subtitle
    }

    private var isSearching: Bool {
        viewModel.searchQuery != nil
    }

    /// Tapping runs `onTitleTap`; long-pressing searches the chat. The pill draws its own capsule, so the pointer's
    /// hover outline (on a Mac) is turned off.
    private var titlePill: some View {
        ChatTitlePill(title: displayTitle, subtitle: displaySubtitle, network: viewModel.network, avatar: viewModel.titleAvatar)
            .contentShape(.capsule)
            .onTapGesture { onTitleTap?() }
            .onLongPressGesture(minimumDuration: 0.4) { viewModel.beginSearch() }
            .sensoryFeedback(.impact, trigger: isSearching) { _, searching in searching }
            .accessibilityAddTraits(onTitleTap == nil ? [] : .isButton)
            .accessibilityAction(named: "Search Messages") { viewModel.beginSearch() }
            .hoverEffectDisabled()
    }

    /// Escape with a hardware keyboard (a Mac, an iPad) ends a search, else goes back to Chats. The composer takes
    /// Escape before this does, so it goes back through `goBack` while typing.
    private var backShortcut: some View {
        Button {
            if isSearching {
                viewModel.endSearch()
            } else {
                dismiss()
            }
        } label: {
            EmptyView()
        }
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityHidden(true)
        .hidden()
    }

    public var body: some View {
        ChatUIKitView(viewModel: viewModel, showProfile: showProfile, goBack: { dismiss() })
            .ignoresSafeArea(.keyboard)
            // Full-bleed under the bar and home indicator; the list insets itself from the safe area.
            .ignoresSafeArea(edges: [.top, .bottom])
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            // Messages scroll under the bar, which has no background on iOS 26; the title and subtitle sit in a
            // floating pill. `.toolbarBackground(.hidden)` here hid the Chats search field's background while
            // swiping back, until the pop finished.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    titlePill
                }
            }
            // On a background, so starting and ending a search doesn't rebuild the chat's view and lose its place.
            .background {
                if isSearching, !ChatPlainSearchField.isNeeded {
                    ChatSearchField(viewModel: viewModel)
                }
            }
            .background { backShortcut }
            .modifier(ChatPlainSearchBar(viewModel: viewModel, isSearching: isSearching))
            .task {
                ChatKit.onEvent(.opened(network: viewModel.network))
                await viewModel.connect()
            }
            .onDisappear {
                guard !keepsConnection else { return }
                viewModel.endSearch()
                viewModel.disconnect()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await viewModel.connect() }
            }
    }
}

/// The shared chat for a network without screens of its own, such as Spotify and Instagram.
public struct NetworkChatView: View {
    @StateObject private var viewModel: ChatViewModel

    public init(viewModel: @autoclosure @escaping () -> ChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    public var body: some View {
        ChatView(viewModel: viewModel)
    }
}

/// The app's search field under the chat's title while searching, focused as it appears. Its Cancel ends the
/// search; Return looks further back when nothing loaded matches.
private struct ChatSearchField: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var text = ""
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .searchable(text: $text, isPresented: $isPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Messages")
            .onSubmit(of: .search) { Task { await viewModel.submitSearch() } }
            .onChange(of: text) { _, query in viewModel.updateSearch(query) }
            .onChange(of: isPresented) { _, presented in
                if !presented { viewModel.endSearch() }
            }
            .task {
                // Presenting in the same pass the field appears doesn't take.
                try? await Task.sleep(for: .milliseconds(150))
                isPresented = true
            }
    }
}

/// Pins the Mac's search field under the bar while searching. In the bar itself (in place of the title pill) it
/// never took focus.
private struct ChatPlainSearchBar: ViewModifier {
    @ObservedObject var viewModel: ChatViewModel
    let isSearching: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), ChatPlainSearchField.isNeeded {
            content.safeAreaBar(edge: .top) {
                if isSearching {
                    ChatPlainSearchField(viewModel: viewModel)
                }
            }
        } else {
            content
        }
    }
}

/// Searching a chat on a Mac: a plain field under the bar. There, presenting the system search
/// controller of a field in the navigation bar throws on macOS 27 (observed 2026-11-17, 27.0.1): its layout asks
/// `UINavigationBar` for its default size, which reads the main screen's scene bounds through screen-based focus,
/// unsupported when an app without multiple scenes runs on a Mac. Done or Escape ends the search.
/// Temporary: try the system search field again with each new iOS/macOS release and remove this once it works.
private struct ChatPlainSearchField: View {
    static let isNeeded = ProcessInfo.processInfo.isiOSAppOnMac

    @ObservedObject var viewModel: ChatViewModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                field.glassEffect(.regular, in: .capsule)
            } else {
                field.background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .onChange(of: text) { _, query in viewModel.updateSearch(query) }
        .task {
            // Focusing in the same pass the field appears doesn't take.
            try? await Task.sleep(for: .milliseconds(150))
            isFocused = true
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Messages", text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { Task { await viewModel.submitSearch() } }
            Button("Done") { viewModel.endSearch() }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

private struct ChatTitlePill: View {
    let title: String
    let subtitle: String
    let network: ChatNetwork
    /// Leads with the chat's picture, as its Chats row does.
    var avatar: ChatTitleAvatar?

    var body: some View {
        let content = HStack(spacing: 8) {
            if let avatar {
                ChatAvatarImage(url: avatar.url, title: title, size: 32, colorKey: avatar.colorKey)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = ChatKit.networkIcon {
                            // An opaque backing, since some badges (such as Spotify's round logo) have transparent corners.
                            icon(network, 12)
                                .clipShape(Circle())
                                .padding(1)
                                .background(Color(uiColor: .systemBackground), in: Circle())
                                .offset(x: 2, y: 2)
                        }
                    }
            }
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    // Without an avatar or subtitle to carry it, the network icon leads the title.
                    if avatar == nil, subtitle.isEmpty, let icon = ChatKit.networkIcon {
                        icon(network, 14)
                    }
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                }
                if !subtitle.isEmpty {
                    HStack(spacing: 4) {
                        // Without an avatar to carry it, the network icon leads the subtitle.
                        if avatar == nil, let icon = ChatKit.networkIcon {
                            icon(network, 12)
                        }
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(subtitle == ChatPresence.online.text ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.leading, avatar == nil ? 18 : 5)
        .padding(.trailing, 18)
        .padding(.vertical, 5)

        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
