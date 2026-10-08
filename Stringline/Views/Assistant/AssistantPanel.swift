import SwiftUI
import AppKit

// MARK: - Brand pieces

/// OpenAI's ChatGPT logo, used unchanged from OpenAI's sign-in assets.
struct ChatGPTLogo: View {
    var size: CGFloat = 16
    var white = false
    var body: some View {
        Image(white ? "ChatGPTLogoWhite" : "ChatGPTLogoBlack")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("ChatGPT")
    }
}

/// OpenAI's "Continue with ChatGPT" button: black, white logo.
struct ContinueWithChatGPTButton: View {
    @Environment(Assistant.self) private var assistant
    var forceConsent = false
    var label = "Continue with ChatGPT"

    var body: some View {
        Button {
            assistant.account.signIn(forceConsent: forceConsent)
        } label: {
            HStack(spacing: 9) {
                ChatGPTLogo(size: 20, white: true)
                Text(label).font(.ui(14, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(assistant.account.isSigningIn)
    }
}

/// The app's own assistant mark (not OpenAI's).
struct AssistantMark: View {
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: "bubble.left.fill")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .frame(width: size, height: size)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct BillingLine: View {
    @Environment(Assistant.self) private var assistant
    var body: some View {
        HStack(spacing: 6) {
            switch assistant.account.billing {
            case .chatGPTPlan:
                ChatGPTLogo(size: 13)
                Text("Using ChatGPT plan").font(.ui(12, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("·").foregroundStyle(Palette.tertiary)
                Link("Manage usage", destination: OpenAIAuthConfig.usageURL).font(.ui(12, weight: .semibold)).foregroundStyle(Palette.amberInk)
            case .apiKey:
                Image(systemName: "key").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                Text("Using your OpenAI API key").font(.ui(12, weight: .semibold)).foregroundStyle(Palette.ink)
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .font(.ui(12))
    }
}

// MARK: - Panel

struct AssistantPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(Assistant.self) private var assistant
    @Environment(\.undoManager) private var undoManager
    @FocusState private var composerFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            contextBar
            Hairline()
            if assistant.account.isReady {
                conversation
                composer
            } else {
                ConnectPrompt()
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 1) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .background(Palette.accentWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(Label("Drop pictures or PDFs to attach", systemImage: "paperclip").font(.ui(14, weight: .bold)))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard assistant.account.isReady else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in assistant.attach([url]) }
                }
            }
            return true
        }
        .onAppear {
            assistant.undoManager = undoManager
            composerFocused = true
        }
        .onChange(of: undoManager) { _, manager in assistant.undoManager = manager }
    }

    private var header: some View {
        HStack(spacing: 6) {
            AssistantMark()
            Text("Assistant").font(.ui(15, weight: .bold)).lineLimit(1).fixedSize()
            Spacer(minLength: 2)
            ModeSwitch().helpSpot("assistant.mode")
            HistoryButton().helpSpot("assistant.history")
            Menu {
                Button("New Chat") { assistant.newChat() }.disabled(assistant.items.isEmpty)
                Divider()
                Button("Assistant Settings…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Assistant menu")
            Button {
                assistant.toggle()
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondary)
            .help("Close (⌘J)")
            .accessibilityLabel("Close assistant")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 54)
    }

    private var contextBar: some View {
        @Bindable var assistant = assistant
        return HStack(spacing: 8) {
            Image(systemName: assistant.shareScreen ? "eye" : "eye.slash")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            if assistant.shareScreen {
                (Text("Sees ").foregroundColor(Palette.secondary) + Text(assistant.breadcrumb).bold().foregroundColor(Palette.ink))
                    .font(.ui(12)).lineLimit(1).truncationMode(.middle)
                    .help("The assistant sees the screen you have open, so “this” means what you're looking at.")
            } else {
                Text("Screen hidden · it only looks things up when you ask").font(.ui(12)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(assistant.shareScreen ? "Hide screen" : "Show screen") { assistant.shareScreen.toggle() }
                .buttonStyle(SmallButtonStyle())
                .help(assistant.shareScreen ? "Stop sending what's on your screen with each message" : "Send what's on your screen with each message")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Palette.surfaceSunk)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if assistant.showsPlanWelcome { PlanWelcome() }
                    if assistant.items.isEmpty { EmptyIntro() }
                    ForEach(assistant.items) { item in
                        ChatRow(item: item).id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: assistant.items.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: lastItemSize) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: assistant.isRunning) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var lastItemSize: Int {
        switch assistant.items.last?.kind {
        case .reply(let text, _): text.count
        case .run(let log): log.steps.count * 1000 + (assistant.status?.count ?? 0)
        default: 0
        }
    }

    private var composer: some View {
        @Bindable var assistant = assistant
        return VStack(alignment: .leading, spacing: 10) {
            if assistant.items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(assistant.suggestions, id: \.self) { text in
                        Button(text) { assistant.send(text) }
                            .buttonStyle(ChipButtonStyle())
                            .disabled(assistant.isRunning)
                    }
                }
            }
            if !assistant.steering.isEmpty {
                Label("It'll read your note at its next step.", systemImage: "arrow.turn.down.right")
                    .font(.ui(11.5, weight: .semibold)).foregroundStyle(Palette.infoInk)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !assistant.attachments.isEmpty { AttachmentStrip(files: assistant.attachments, removable: true) }
                TextField(placeholder, text: $assistant.composer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.ui(13.5))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit { assistant.send() }
                    .accessibilityLabel("Message the assistant")
                HStack(spacing: 6) {
                    AttachMenu().helpSpot("assistant.attach")
                    ComposerToggle(icon: "globe", on: assistant.prefs.webSearch && !assistant.webSearchUnavailable,
                                   help: assistant.webSearchUnavailable ? "Web search isn't available on this account" : (assistant.prefs.webSearch ? "Web search is on" : "Web search is off")) {
                        assistant.updatePrefs { $0.webSearch.toggle() }
                    }
                    .disabled(assistant.webSearchUnavailable)
                    .helpSpot("assistant.web")
                    ComposerToggle(icon: "mic", on: false, help: "Dictate (uses macOS Dictation)") {
                        composerFocused = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Dictation.start() }
                    }
                    .helpSpot("assistant.mic")
                    Text(assistant.mode == .chat ? "Chat · looks only" : "Action · you apply changes")
                        .font(.ui(11.5, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1)
                        .padding(.leading, 2)
                    Spacer(minLength: 2)
                    if assistant.isRunning {
                        Button {
                            assistant.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill").font(.ui(12, weight: .bold))
                        }
                        .buttonStyle(SmallButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .help("Stop (Esc)")
                    }
                    Button {
                        assistant.send()
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 30, height: 30)
                            .background(canSend ? Palette.accent : Palette.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(assistant.isRunning ? "Add this while it works" : "Send (Return)")
                    .accessibilityLabel(assistant.isRunning ? "Add to what it's doing" : "Send")
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 8))
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(composerFocused ? Palette.ink : Color(hex: 0xDCDCD7), lineWidth: 1.5))
            .helpSpot("assistant.composer")
            BillingLine()
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .overlay(alignment: .top) { Hairline() }
    }

    private var canSend: Bool {
        !assistant.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!assistant.attachments.isEmpty && !assistant.isRunning)
    }

    private var placeholder: String {
        if assistant.isRunning { return "Add something while it works…" }
        if assistant.mode == .action { return "Tell it what to change…" }
        if case .job(_) = store.selection { return "Ask about this \(store.jobTab == .estimate ? "estimate" : "job"), or how to do anything…" }
        return "Ask anything, or how to do something…"
    }

    private func openSettings() {
        store.settingsSectionRequest = .assistant
        store.selection = .settings
    }
}

private struct ComposerToggle: View {
    let icon: String
    let on: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Palette.ink : Palette.secondary)
                .frame(width: 28, height: 28)
                .background(on ? Palette.accentWash : Palette.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? Palette.accent : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct AttachMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(Assistant.self) private var assistant

    var body: some View {
        Menu {
            Button("Choose files…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.allowedContentTypes = [.image, .pdf]
                panel.prompt = "Attach"
                if panel.runModal() == .OK { assistant.attach(panel.urls) }
            }
            if case .job(let id) = store.selection, let job = store.job(id), let folder = store.photosFolder(job) {
                Button("This job's photos…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.image, .pdf]
                    panel.directoryURL = folder
                    panel.prompt = "Attach"
                    if panel.runModal() == .OK { assistant.attach(panel.urls) }
                }
            }
        } label: {
            Image(systemName: "paperclip").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("Attach pictures or PDFs (or drag them onto the panel)")
        .accessibilityLabel("Attach pictures or PDFs")
    }
}

struct AttachmentStrip: View {
    @Environment(Assistant.self) private var assistant
    let files: [Attachment]
    var removable = false

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(files) { file in
                HStack(spacing: 6) {
                    if let data = file.preview, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Image(systemName: file.kind == .pdf ? "doc.richtext" : "photo").font(.system(size: 13)).frame(width: 26, height: 26)
                    }
                    Text(file.name).font(.ui(11.5, weight: .semibold)).lineLimit(1).frame(maxWidth: 130, alignment: .leading)
                    if removable {
                        Button {
                            assistant.removeAttachment(file.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(file.name)")
                    }
                }
                .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 3)
                .background(Palette.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct HistoryButton: View {
    @Environment(Assistant.self) private var assistant
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.secondary)
        .help("Earlier chats")
        .accessibilityLabel("Earlier chats")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Earlier chats").font(.ui(14, weight: .bold))
                    Spacer()
                    Button("New Chat") { assistant.newChat(); showing = false }.buttonStyle(SmallButtonStyle())
                }
                .padding(12)
                Divider()
                if !assistant.prefs.keepHistory {
                    Text("Chat history is off. Turn it on in Settings › AI assistant.").font(.ui(12.5)).foregroundStyle(Palette.secondary).padding(14)
                } else if assistant.chats.isEmpty {
                    Text("No earlier chats yet.").font(.ui(12.5)).foregroundStyle(Palette.secondary).padding(14)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(assistant.chats.prefix(60)) { chat in
                                HStack(spacing: 8) {
                                    Button {
                                        assistant.openChat(chat.id)
                                        showing = false
                                    } label: {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(chat.title).font(.ui(12.5, weight: chat.id == assistant.conversationID ? .bold : .semibold))
                                                .foregroundStyle(Palette.ink).lineLimit(1)
                                            Text(chat.updated.formatted(.relative(presentation: .named))).font(.ui(11)).foregroundStyle(Palette.tertiary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Button {
                                        assistant.deleteChat(chat.id)
                                    } label: {
                                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete this chat")
                                    .accessibilityLabel("Delete \(chat.title)")
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(alignment: .bottom) { Hairline() }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            }
            .frame(width: 320)
        }
    }
}

// MARK: - Mode switch

struct ModeSwitch: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        HStack(spacing: 0) {
            segment(.chat, icon: "bubble.left")
            segment(.action, icon: "bolt.fill")
        }
        .padding(3)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
        .help("Chat looks things up. Action lines up changes for you to apply. ⌘⇧J switches.")
    }

    private func segment(_ mode: AssistantMode, icon: String) -> some View {
        let active = assistant.mode == mode
        return Button {
            assistant.setMode(mode)
        } label: {
            Label(mode.label, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .font(.ui(12, weight: active ? .bold : .semibold))
                .foregroundStyle(active ? (mode == .action ? .white : Palette.ink) : Palette.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(mode == .action ? Palette.ink : Palette.surface)
                            .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Rows

private struct ChatRow: View {
    @Environment(AppStore.self) private var store
    @Environment(Assistant.self) private var assistant
    let item: Assistant.Item
    @State private var hovering = false

    private var isLastUser: Bool {
        assistant.items.last(where: { if case .user = $0.kind { return true }; return false })?.id == item.id
    }

    private var isLastReply: Bool {
        assistant.items.last(where: { if case .reply = $0.kind { return true }; return false })?.id == item.id
    }

    var body: some View {
        switch item.kind {
        case .user(let text, let files):
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 6) {
                        if !files.isEmpty { AttachmentStrip(files: files) }
                        Text(text)
                            .font(.ui(13.5))
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Palette.chip, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous))
                }
                HStack(spacing: 2) {
                    ActionButton(icon: "doc.on.doc", label: "Copy") { assistant.copyText(text) }
                    if isLastUser && !assistant.isRunning {
                        ActionButton(icon: "pencil", label: "Edit") { assistant.editLast() }
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            .onHover { hovering = $0 }
        case .reply(let text, let sources):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ChatGPTLogo(size: 13)
                    Text("ChatGPT").font(.ui(11.5, weight: .bold)).foregroundStyle(Palette.secondary)
                    Text(item.date.formatted(date: .omitted, time: .shortened)).font(.ui(11)).foregroundStyle(Palette.tertiary).opacity(hovering ? 1 : 0)
                }
                MarkdownText(text: text)
                if !sources.isEmpty { SourceList(sources: sources) }
                HStack(spacing: 2) {
                    ActionButton(icon: "doc.on.doc", label: "Copy") { assistant.copyText(text) }
                    ActionButton(icon: assistant.speakingID == item.id ? "stop.circle" : "speaker.wave.2",
                                 label: assistant.speakingID == item.id ? "Stop reading" : "Read aloud") { assistant.readAloud(text, id: item.id) }
                    if isLastReply && !assistant.isRunning {
                        ActionButton(icon: "arrow.clockwise", label: "Try again") { assistant.regenerate() }
                    }
                }
                .opacity(hovering || assistant.speakingID == item.id ? 1 : 0)
            }
            .onHover { hovering = $0 }
        case .run(let log):
            RunCard(log: log, active: item.id == assistant.runItemID, status: assistant.status)
        case .notice(let text, let action):
            NoticeRow(text: text, action: action)
        case .open(let suggestion):
            Button {
                assistant.use(suggestion)
            } label: {
                Label(suggestion.label, systemImage: suggestion.external != nil ? "map" : suggestion.spot != nil ? "hand.point.up.left" : "arrow.up.forward.square")
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(SmallButtonStyle())
        case .changes(let id):
            ChangeCard(proposalID: id)
        case .pastChanges(let title, let lines, let state):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(title, systemImage: "bolt.fill").font(.ui(12.5, weight: .bold))
                    Spacer()
                    Text(state).font(.ui(11.5)).foregroundStyle(Palette.tertiary)
                }
                ForEach(lines, id: \.self) { Text($0).font(.ui(12)).foregroundStyle(Palette.secondary) }
            }
            .padding(12)
            .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }
}

private struct ActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A reply with its lists, steps and bold text laid out properly. Links are never clickable here.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(Self.inline(s)).font(.ui(13.5)).foregroundStyle(Color(hex: 0x2B2D31)).lineSpacing(2)
        case .heading(let level, let s):
            Text(Self.inline(s)).font(.ui(level <= 2 ? 15 : 14, weight: .bold)).foregroundStyle(Palette.ink).padding(.top, 2)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Palette.tertiary).frame(width: 5, height: 5).offset(y: -2)
                        Text(Self.inline(s)).font(.ui(13.5)).foregroundStyle(Color(hex: 0x2B2D31))
                    }
                }
            }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(start + i)").font(.ui(11.5, weight: .bold)).foregroundStyle(.white).monospacedDigit()
                            .frame(minWidth: 20, minHeight: 20).background(Palette.ink, in: Circle())
                        Text(Self.inline(s)).font(.ui(13.5)).foregroundStyle(Palette.ink).lineSpacing(2)
                    }
                }
            }
        case .quote(let s):
            Text(Self.inline(s)).font(.ui(13)).foregroundStyle(Palette.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.control).frame(width: 3) }
        case .code(let s):
            Text(s).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Hairline()
        }
    }

    /// Inline markdown (bold, italics, code). Links are shown as plain text, never as something to click.
    static func inline(_ text: String) -> AttributedString {
        guard var out = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in out.runs where run.link != nil { out[run.range].link = nil }
        return out
    }
}

private struct SourceList: View {
    let sources: [Source]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SOURCES").font(.eyebrow).tracking(0.6).foregroundStyle(Palette.tertiary)
            FlowLayout(spacing: 6) {
                ForEach(sources.prefix(8), id: \.self) { source in
                    if let url = source.safeURL {
                        Link(destination: url) {
                            HStack(spacing: 5) {
                                Image(systemName: "globe").font(.system(size: 10, weight: .semibold))
                                Text(source.host).font(.ui(11.5, weight: .semibold)).lineLimit(1)
                            }
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Palette.chip, in: Capsule())
                        }
                        .foregroundStyle(Palette.ink)
                        .help(source.title)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

/// What the assistant did on one turn, step by step, like a work log.
private struct RunCard: View {
    let log: RunLog
    let active: Bool
    let status: String?
    @State private var expanded: Bool?

    private var isOpen: Bool { expanded ?? (active || log.steps.count <= 4) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded = !isOpen
            } label: {
                HStack(spacing: 7) {
                    headerIcon
                    Text(title).font(.ui(12, weight: .semibold)).foregroundStyle(Palette.secondary)
                    Spacer(minLength: 0)
                    if !log.steps.isEmpty {
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(log.steps.isEmpty)
            .accessibilityLabel(title)
            if isOpen {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(log.steps) { step in
                        Label {
                            Text(step.text).font(.ui(12)).lineLimit(2)
                        } icon: {
                            Image(systemName: step.state == .failed ? "exclamationmark.triangle" : step.icon).font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(step.state == .failed ? Palette.noGoInk : Palette.tertiary)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var headerIcon: some View {
        if active {
            ProgressView().controlSize(.small)
        } else {
            switch log.state {
            case .done, .running: Image(systemName: "checkmark.circle").foregroundStyle(Palette.goInk)
            case .stopped: Image(systemName: "stop.circle").foregroundStyle(Palette.secondary)
            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.noGoInk)
            }
        }
    }

    private var title: String {
        if active { return status ?? "Working…" }
        let count = log.steps.count == 1 ? "1 step" : "\(log.steps.count) steps"
        let seconds = Int((log.ended ?? .now).timeIntervalSince(log.started).rounded())
        switch log.state {
        case .stopped: return "Stopped · \(count)"
        case .failed: return "Didn't finish · \(count)"
        default: return "Worked for \(seconds)s · \(count)"
        }
    }
}

private struct NoticeRow: View {
    @Environment(AppStore.self) private var store
    @Environment(Assistant.self) private var assistant
    let text: String
    let action: Assistant.NoticeAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(Palette.watchInk)
                Text(text).font(.ui(12.5)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                switch action {
                case .manageUsage:
                    Link(destination: OpenAIAuthConfig.usageURL) {
                        HStack(spacing: 6) { ChatGPTLogo(size: 13); Text("Manage usage") }
                    }
                    .buttonStyle(SmallButtonStyle())
                case .openSettings:
                    Button("Open Settings › AI assistant") {
                        store.settingsSectionRequest = .assistant
                        store.selection = .settings
                    }
                    .buttonStyle(SmallButtonStyle())
                case .switchToAction:
                    Button("Switch to Action") { assistant.setMode(.action) }.buttonStyle(SmallButtonStyle())
                case .retry:
                    Button("Try again") { assistant.retry() }.buttonStyle(SmallButtonStyle()).disabled(assistant.isRunning)
                case .continueRun:
                    Button("Continue") { assistant.continueRun() }.buttonStyle(SmallButtonStyle()).disabled(assistant.isRunning)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.watchBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Change card

struct ChangeCard: View {
    @Environment(Assistant.self) private var assistant
    let proposalID: UUID

    var body: some View {
        if let p = assistant.proposals[proposalID] {
            let ticked = p.changes.filter(\.isOn).count
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent)
                    Text(p.changes.count == 1 ? "1 change" : "\(p.changes.count) changes").font(.ui(13, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    Text(headerNote(p)).font(.ui(11.5)).foregroundStyle(Palette.onDarkMuted)
                }
                .padding(.horizontal, 14).frame(height: 38)
                .background(Palette.ink)

                ForEach(p.changes) { change in
                    ChangeRow(change: change, state: p.state) { on in
                        assistant.setChange(change.id, on: on, in: proposalID)
                    }
                    .overlay(alignment: .top) { Hairline() }
                }

                let impact = assistant.impact(of: proposalID)
                if !impact.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(impact, id: \.self) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(impact.count > 1 ? "\(row.job) bid" : "Bid price").font(.ui(12)).foregroundStyle(Palette.secondary)
                                Spacer()
                                if row.before > 0 {
                                    Text(Fmt.dollars(row.before)).font(.ui(12)).strikethrough().foregroundStyle(Palette.tertiary).monospacedDigit()
                                }
                                Text(Fmt.dollars(row.after)).font(.display(18)).foregroundStyle(Palette.ink).monospacedDigit()
                            }
                            if let perSY = row.perSYAfter {
                                Text(String(format: "$%.2f per SY", perSY)).font(.ui(11.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Palette.surfaceSunk)
                    .overlay(alignment: .top) { Hairline() }
                }

                footer(p, ticked: ticked)
                    .overlay(alignment: .top) { Hairline() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(p.state == .pending ? Palette.ink : Palette.border, lineWidth: p.state == .pending ? 1.5 : 1))
        }
    }

    private func headerNote(_ p: Assistant.Proposal) -> String {
        switch p.state {
        case .pending: "Not saved yet"
        case .applied: "Applied"
        case .undone: "Undone"
        case .discarded: "Discarded"
        }
    }

    @ViewBuilder
    private func footer(_ p: Assistant.Proposal, ticked: Int) -> some View {
        switch p.state {
        case .pending:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        assistant.apply(proposalID)
                    } label: {
                        Label(ticked == 0 ? "Tick a change to apply" : ticked == 1 ? "Apply 1 change" : "Apply \(ticked) changes", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(ticked == 0 || assistant.isRunning)
                    .opacity(ticked == 0 || assistant.isRunning ? 0.45 : 1)
                    Button("Discard") { assistant.discard(proposalID) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(assistant.isRunning)
                    Spacer()
                }
                Text(assistant.isRunning ? "Still working. Apply when it's done." : "Saved like your own edits, kept in History. ⌘Z undoes it.")
                    .font(.ui(11.5)).foregroundStyle(Palette.tertiary)
            }
            .padding(12)
        case .applied:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.goInk)
                    Text(p.appliedCount == 1 ? "Applied 1 change" : "Applied \(p.appliedCount) changes").font(.ui(13, weight: .bold)).foregroundStyle(Palette.goInk)
                    Spacer()
                    Button {
                        assistant.undo(proposalID)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(SmallButtonStyle())
                }
                notes(p.notes)
            }
            .padding(12)
            .background(Palette.goBg)
        case .undone:
            VStack(alignment: .leading, spacing: 6) {
                Label("Undone. Things are back the way they were.", systemImage: "arrow.uturn.backward.circle")
                    .font(.ui(12.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                notes(p.notes)
            }
            .padding(12)
        case .discarded:
            Label("Discarded. Nothing was saved.", systemImage: "xmark.circle")
                .font(.ui(12.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                .padding(12)
        }
    }

    @ViewBuilder
    private func notes(_ notes: [String]) -> some View {
        ForEach(notes, id: \.self) { note in
            Text(note).font(.ui(11.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChangeRow: View {
    let change: ProposedChange
    let state: Assistant.Proposal.State
    let toggle: (Bool) -> Void

    private var editable: Bool { state == .pending }
    private var happened: Bool { change.isOn && state == .applied }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if editable {
                Toggle("", isOn: Binding(get: { change.isOn }, set: toggle))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(change.title)
            } else {
                Image(systemName: happened ? "checkmark.circle.fill" : "minus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(happened ? Palette.goInk : Palette.tertiary)
                    .frame(width: 16)
                    .accessibilityLabel(happened ? "Applied" : "Not applied")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(change.title).font(.ui(13, weight: .semibold)).foregroundStyle(change.isOn && state != .discarded ? Palette.ink : Palette.tertiary)
                    .strikethrough(state == .undone || state == .discarded, color: Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !change.detail.isEmpty {
                    Text(change.detail).font(.ui(12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if change.needsOK && editable {
                    Label(change.isOn ? "You've OK'd this" : "Needs your OK: tick it to include", systemImage: change.isOn ? "checkmark.seal" : "hand.raised")
                        .font(.ui(11, weight: .bold))
                        .foregroundStyle(Palette.watchInk)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Palette.watchBg, in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if editable { toggle(!change.isOn) } }
    }
}

// MARK: - Empty and connect states

private struct EmptyIntro: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(assistant.mode == .chat ? "Ask about your jobs, or how to do anything" : "Tell it what to change")
                .font(.ui(15, weight: .bold))
            Text(assistant.mode == .chat
                 ? "It reads the screen you're on, so “this job” just works, and it knows Stringline's help, so “how do I…” gets step-by-step answers it can point to on screen. It won't change anything in Chat."
                 : "It lines up the changes on a card. Nothing is saved until you press Apply, and ⌘Z undoes it. Mail, Messages and Calendar only open when you tick them.")
                .font(.ui(12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

private struct PlanWelcome: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChatGPTLogo(size: 20)
                .frame(width: 34, height: 34)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.border))
            VStack(alignment: .leading, spacing: 4) {
                Text("You're using your ChatGPT plan").font(.ui(13, weight: .bold))
                Text("Stringline doesn't charge for the assistant. Requests count toward your ChatGPT plan, up to the limit you set in ChatGPT.")
                    .font(.ui(12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Got it") { assistant.updatePrefs { $0.planWelcomeSeen = true } }
                    .buttonStyle(SmallButtonStyle()).padding(.top, 4)
            }
        }
        .padding(12)
        .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
    }
}

struct ConnectPrompt: View {
    @Environment(AppStore.self) private var store
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack(spacing: 14) {
            ConnectionArt()
            Text("Bring ChatGPT into Stringline").font(.display(24)).multilineTextAlignment(.center)
            Text("Ask about any job, or tell it what to change. It always knows which screen you're on.")
                .font(.ui(13)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if case .waitingForBrowser = assistant.account.phase {
                SignInWaiting()
            } else if assistant.account.phase == .finishing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the sign-in with OpenAI…").font(.ui(13)) }
            } else {
                ContinueWithChatGPTButton()
                if assistant.account.hasRegistration {
                    Button("Use a different ChatGPT account or workspace") { assistant.account.useDifferentAccount() }
                        .buttonStyle(LinkButtonStyle())
                }
            }
            Button("Use an OpenAI API key instead") {
                store.settingsSectionRequest = .assistant
                store.selection = .settings
            }
            .buttonStyle(LinkButtonStyle())
            if let message = assistant.account.message {
                Text(message).font(.ui(12)).foregroundStyle(Palette.noGoInk).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("You sign in on openai.com in your browser. Stringline never sees your password, and keeps the sign-in in this Mac's Keychain.")
                .font(.ui(11.5)).foregroundStyle(Palette.tertiary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }
}

struct ConnectionArt: View {
    var body: some View {
        HStack(spacing: 6) {
            LogoMark(size: 48)
            Rectangle().fill(.clear).frame(width: 22, height: 2)
                .overlay(Line().stroke(Color(hex: 0xC9C9C3), style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
            ChatGPTLogo(size: 28)
                .frame(width: 48, height: 48)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Palette.border))
        }
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

struct SignInWaiting: View {
    @Environment(Assistant.self) private var assistant
    var leading = false

    var body: some View {
        VStack(alignment: leading ? .leading : .center, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let waited = Int(context.date.timeIntervalSince(assistant.account.phaseStarted ?? context.date))
                VStack(alignment: leading ? .leading : .center, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finish in your browser").font(.ui(13.5, weight: .bold))
                        Text(String(format: "%d:%02d", waited / 60, waited % 60)).font(.ui(12).monospacedDigit()).foregroundStyle(Palette.tertiary)
                    }
                    Text(waited < 45
                         ? "Sign in to ChatGPT there and allow Stringline. This updates the moment you're done."
                         : "Still waiting for the browser. Didn't see a page? Click Open the page again. Signed in but nothing happened? Click Cancel and try once more.")
                        .font(.ui(12)).foregroundStyle(waited < 45 ? Palette.secondary : Palette.watchInk)
                        .multilineTextAlignment(leading ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Open the page again") { assistant.account.reopenSignInPage() }.buttonStyle(SmallButtonStyle())
                Button("Cancel") { assistant.account.cancelSignIn() }.buttonStyle(SmallButtonStyle())
            }
        }
    }
}

// MARK: - Small helpers

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(configuration.isPressed ? Palette.border : Palette.chip, in: Capsule())
            .contentShape(Capsule())
    }
}
