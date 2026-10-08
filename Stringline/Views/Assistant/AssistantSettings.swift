import SwiftUI
import AppKit

/// Settings › AI assistant.
struct AssistantSettings: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI assistant").font(.display(26))
                Text("Ask about your jobs, or have it do the work. It always knows which screen you're on. Open it anywhere with ⌘J.")
                    .font(.ui(13)).foregroundStyle(Palette.secondary)
            }
            ConnectionCard()
            if assistant.account.isReady { ModelCard() }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    ModesCard()
                    ChatOptionsCard()
                    PermissionsCard()
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 16) {
                    PrivacyCard()
                    ShortcutsCard()
                }
                .frame(width: 300)
            }
        }
    }
}

// MARK: - Connection

private struct ConnectionCard: View {
    @Environment(Assistant.self) private var assistant
    @State private var keyText = ""
    @State private var showKeyField = false
    @State private var keyError: String?
    @State private var checking = false
    @State private var signingOut = false

    private var account: AIAccount { assistant.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let session = account.session {
                signedIn(session)
            } else if case .waitingForBrowser = account.phase {
                HStack(alignment: .top, spacing: 16) {
                    ConnectionArt()
                    SignInWaiting(leading: true).frame(maxWidth: 420, alignment: .leading)
                }
            } else {
                signedOut
            }
            if let message = account.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.watchInk)
                    Text(message).font(.ui(12.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { account.message = nil }.buttonStyle(SmallButtonStyle())
                }
                .padding(10)
                .background(Palette.watchBg, in: RoundedRectangle(cornerRadius: 9))
            }
            if assistant.showsPlanWelcome {
                HStack(spacing: 12) {
                    ChatGPTLogo(size: 22)
                        .frame(width: 36, height: 36)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You're using your ChatGPT plan").font(.ui(13, weight: .bold))
                        Text("Stringline doesn't charge for the assistant. Requests count toward your ChatGPT plan, up to the limit you set in ChatGPT.")
                            .font(.ui(12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button("Got it") { assistant.updatePrefs { $0.planWelcomeSeen = true } }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(14)
                .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 12))
            }
            Hairline()
            apiKeySection
        }
        .card(padding: 22)
    }

    private var signedOut: some View {
        HStack(alignment: .top, spacing: 20) {
            ConnectionArt()
            VStack(alignment: .leading, spacing: 8) {
                Text("NOT CONNECTED").font(.eyebrow).tracking(0.7).foregroundStyle(Palette.tertiary)
                Text("Bring ChatGPT into Stringline").font(.display(24))
                Text("Sign in with your ChatGPT account. Then ask about any job, or tell it what to change. You never have to explain which job or screen you mean.")
                    .font(.ui(13.5)).foregroundStyle(Color(hex: 0x3F4249)).fixedSize(horizontal: false, vertical: true)
                if account.phase == .finishing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the sign-in with OpenAI…").font(.ui(13)) }.padding(.top, 6)
                } else {
                    ContinueWithChatGPTButton().padding(.top, 6)
                    if account.hasRegistration {
                        Button("Use a different ChatGPT account or workspace") { account.useDifferentAccount() }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
                Text("You sign in on openai.com in your browser. Stringline never sees your password, and keeps the sign-in in this Mac's Keychain. Your plan needs to allow apps: personal Plus and Pro do. Business, Enterprise and Edu workspaces may not; use an API key for those.")
                    .font(.ui(12)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signedIn(_ session: AIAccount.Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(account.initials)
                    .font(.display(18)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Palette.ink, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(account.displayName).font(.ui(15, weight: .bold))
                        Pill(text: session.planAllowed ? "Connected" : "Plan use not allowed", tone: session.planAllowed ? .go : .watch,
                             icon: session.planAllowed ? "checkmark" : "exclamationmark")
                    }
                    HStack(spacing: 6) {
                        ChatGPTLogo(size: 13)
                        Text(session.claims.email ?? "ChatGPT account").font(.ui(12.5)).foregroundStyle(Palette.secondary)
                        if session.planAllowed {
                            Text("·").foregroundStyle(Palette.tertiary)
                            Link("Manage usage", destination: OpenAIAuthConfig.usageURL).font(.ui(12.5, weight: .semibold)).foregroundStyle(Palette.amberInk)
                        }
                    }
                }
                Spacer()
                Button {
                    signingOut = true
                    Task {
                        await account.signOut()
                        signingOut = false
                    }
                } label: {
                    Text(signingOut ? "Disconnecting…" : "Disconnect").foregroundStyle(Palette.noGoInk)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(signingOut)
            }
            Button("Use a different ChatGPT account or workspace") { account.useDifferentAccount() }
                .buttonStyle(LinkButtonStyle())
                .disabled(signingOut)
            if !session.planAllowed {
                HStack(spacing: 12) {
                    Text("ChatGPT plan use wasn't allowed when you signed in, so the assistant can't run on your plan.")
                        .font(.ui(12.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    ContinueWithChatGPTButton(forceConsent: true, label: "Allow plan use")
                }
                .padding(12)
                .background(Palette.watchBg, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key").foregroundStyle(Palette.secondary)
                Text("OpenAI API key").font(.ui(13.5, weight: .bold))
                Text("· optional").font(.ui(12.5)).foregroundStyle(Palette.tertiary)
            }
            if let hint = account.apiKeyHint {
                HStack(spacing: 10) {
                    Text("Key \(hint) is saved in this Mac's Keychain. Use is billed to your OpenAI account, not your ChatGPT plan.")
                        .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Remove key") { account.removeAPIKey() }.buttonStyle(SmallButtonStyle())
                }
                if account.session?.planAllowed == true {
                    Toggle("Use the API key instead of my ChatGPT plan", isOn: Binding(
                        get: { assistant.prefs.preferAPIKey },
                        set: { value in assistant.updatePrefs { $0.preferAPIKey = value } }))
                        .toggleStyle(.checkbox).font(.ui(12.5))
                }
            } else if showKeyField {
                HStack(spacing: 8) {
                    FieldBox {
                        SecureField("sk-…", text: $keyText).textFieldStyle(.plain).font(.ui(13)).onSubmit(saveKey)
                            .accessibilityLabel("OpenAI API key")
                    }
                    Button(checking ? "Checking…" : "Save") { saveKey() }.buttonStyle(PrimaryButtonStyle()).disabled(keyText.isEmpty || checking)
                    Button("Cancel") { showKeyField = false; keyText = ""; keyError = nil }.buttonStyle(SecondaryButtonStyle())
                }
                if let keyError { Text(keyError).font(.ui(12)).foregroundStyle(Palette.noGoInk) }
                Text("Make a key at platform.openai.com. It's checked with OpenAI, then kept in your Keychain only.")
                    .font(.ui(12)).foregroundStyle(Palette.tertiary)
            } else {
                HStack {
                    Text("If your ChatGPT plan can't be used from apps, the assistant can use your own OpenAI API key instead. That's billed by OpenAI per use.")
                        .font(.ui(12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Add API key…") { showKeyField = true }.buttonStyle(SmallButtonStyle())
                }
            }
        }
    }

    private func saveKey() {
        let key = keyText
        keyError = nil
        checking = true
        Task {
            defer { checking = false }
            do {
                try await OpenAIClient.check(apiKey: key)
                try account.saveAPIKey(key)
                keyText = ""
                showKeyField = false
            } catch {
                keyError = (error as? LocalizedError)?.errorDescription ?? "OpenAI didn't accept that key."
            }
        }
    }
}

private struct ModelCard: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model").font(.ui(13.5, weight: .bold))
                Text(assistant.modelsError ?? "The list comes from your account. The first one is OpenAI's pick for it.")
                    .font(.ui(12)).foregroundStyle(assistant.modelsError == nil ? Palette.tertiary : Palette.noGoInk)
            }
            Spacer()
            if assistant.models.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Picker("Model", selection: Binding(
                    get: { assistant.prefs.model ?? assistant.models.first?.slug ?? "" },
                    set: { value in assistant.updatePrefs { $0.model = value } })) {
                    ForEach(assistant.models) { Text($0.name).tag($0.slug) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            Button {
                Task { await assistant.loadModels() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(SmallButtonStyle())
            .help("Refresh the list")
        }
        .card(padding: 16)
        .task { if assistant.models.isEmpty { await assistant.loadModels() } }
    }
}

// MARK: - Modes and permissions

private struct ChatOptionsCard: View {
    @Environment(Assistant.self) private var assistant
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Chat", subtitle: "Applies on this Mac.")
            Toggle(isOn: Binding(get: { assistant.prefs.webSearch }, set: { v in assistant.updatePrefs { $0.webSearch = v } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let it search the web").font(.ui(13, weight: .semibold))
                    Text("For prices, products and how-tos. Answers list their sources. Also on the globe button in the panel.").font(.ui(12)).foregroundStyle(Palette.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: Binding(get: { assistant.prefs.keepHistory }, set: { v in assistant.updatePrefs { $0.keepHistory = v } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep chat history on this Mac").font(.ui(13, weight: .semibold))
                    Text("So you can pick up an earlier chat from the clock button. Saved only on this Mac, never in PavingData or iCloud.").font(.ui(12)).foregroundStyle(Palette.secondary)
                }
            }
            .toggleStyle(.checkbox)
            HStack {
                Text(assistant.chats.isEmpty ? "No saved chats." : "\(assistant.chats.count) saved chat\(assistant.chats.count == 1 ? "" : "s").")
                    .font(.ui(12)).foregroundStyle(Palette.tertiary)
                Spacer()
                Button("Delete all chats…") { confirmClear = true }
                    .buttonStyle(SmallButtonStyle())
                    .disabled(assistant.chats.isEmpty)
            }
        }
        .card(padding: 20)
        .confirmationDialog("Delete all saved chats?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { assistant.deleteAllChats() }
        } message: {
            Text("They're removed from this Mac. Your jobs and changes you applied aren't affected.")
        }
    }
}

private struct ModesCard: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Two ways to use it", subtitle: "Pick where it starts. ⌘⇧J switches any time.")
            HStack(alignment: .top, spacing: 12) {
                card(.chat, icon: "bubble.left", text: "Answers questions about the screen you're on and all your jobs. Looks, never touches.", example: "“Is this bid high for this lot?”")
                card(.action, icon: "bolt.fill", text: "Does the work: fills estimates, moves jobs, books crews. You see every change first, and ⌘Z undoes it.", example: "“Add crack sealing and make it 18% profit.”")
            }
        }
        .card(padding: 20)
    }

    private func card(_ mode: AssistantMode, icon: String, text: String, example: String) -> some View {
        let active = assistant.prefs.defaultMode == mode
        return Button {
            assistant.updatePrefs { $0.defaultMode = mode }
            if assistant.items.isEmpty { assistant.setMode(mode) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(active ? Palette.ink : Palette.control)
                VStack(alignment: .leading, spacing: 4) {
                    Label(mode.label, systemImage: icon).font(.ui(14, weight: .bold)).foregroundStyle(Palette.ink)
                    Text(text).font(.ui(12.5)).foregroundStyle(Color(hex: 0x3F4249)).fixedSize(horizontal: false, vertical: true)
                    Text(example).font(.ui(12)).foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Palette.ink : Color(hex: 0xDCDCD7), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct PermissionsCard: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "What it may do in Action mode", subtitle: "Every change waits on a card for you to apply, and is kept in History like your own edits.")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Lines up changes to", systemImage: "arrow.uturn.backward").font(.ui(13, weight: .bold)).foregroundStyle(Palette.goInk)
                    ForEach(ToolArea.allCases) { area in
                        Toggle(area.label, isOn: Binding(
                            get: { assistant.prefs.areas.contains(area) },
                            set: { on in assistant.updatePrefs { if on { $0.areas.insert(area) } else { $0.areas.remove(area) } } }))
                            .toggleStyle(.checkbox).font(.ui(12.5))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 9) {
                    Label("Only if you tick it", systemImage: "hand.raised").font(.ui(13, weight: .bold)).foregroundStyle(Palette.watchInk)
                    bullet("Opening a Mail draft to a customer")
                    bullet("Marking an invoice paid")
                    bullet("Changing a rate in your price list")
                    Label("Never", systemImage: "nosign").font(.ui(13, weight: .bold)).foregroundStyle(Palette.noGoInk).padding(.top, 6)
                    bullet("Sends an email. You press Send in Mail.")
                    bullet("Deletes jobs, customers or photos")
                    bullet("Saves while saving is paused, or over a file it can't read")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0xFFF8E1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .card(padding: 20)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(Palette.tertiary).frame(width: 4, height: 4).offset(y: -2)
            Text(text).font(.ui(12.5)).foregroundStyle(Color(hex: 0x2B2D31)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PrivacyCard: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What it sees", systemImage: "eye").font(.ui(15, weight: .bold)).foregroundStyle(.white)
            Text("With each message, Stringline sends OpenAI:").font(.ui(12.5)).foregroundStyle(Palette.onDarkMuted)
            VStack(alignment: .leading, spacing: 7) {
                dot("Your message")
                dot("The screen you're on, like “Maple Ridge Plaza › Estimate”")
                dot("The records on that screen: lines, totals, areas, dates")
                dot("Job and customer names, so it can find others")
                dot("Anything it looks up to answer you")
            }
            Hairline().opacity(0.2).padding(.vertical, 4)
            Toggle(isOn: Binding(get: { assistant.prefs.shareContact }, set: { value in assistant.updatePrefs { $0.shareContact = value } })) {
                Text("Include customer phone numbers and emails").font(.ui(12.5)).foregroundStyle(Color(hex: 0xE6E7E9))
            }
            .toggleStyle(OnDarkCheckboxStyle())
            Text("Off by default. Mail drafts still go to the right address; it's filled in on this Mac. “Hide screen” in the panel stops sending the screen.")
                .font(.ui(11.5)).foregroundStyle(Palette.onDarkMuted).fixedSize(horizontal: false, vertical: true)
            Text("Chat history stays on this Mac (you can turn it off). Stringline asks OpenAI not to store chats as saved responses. OpenAI's own data policies still apply.")
                .font(.ui(11.5)).foregroundStyle(Palette.onDarkMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Palette.asphalt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func dot(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 5, height: 5).offset(y: -2)
            Text(text).font(.ui(12.5)).foregroundStyle(Color(hex: 0xE6E7E9)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts").font(.ui(15, weight: .bold))
            row("⌘J", "Open or close the assistant")
            row("⌘⇧J", "Switch Chat and Action")
            row("⇧⌘/", "Ask Stringline Help")
            row("⌥⏎", "New line in a message")
            row("Esc", "Stop what it's doing")
            row("⌘Z", "Undo its applied changes")
        }
        .card(padding: 16)
    }

    private func row(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            KeyCap(key: key).frame(width: 46, alignment: .leading)
            Text(text).font(.ui(12.5)).foregroundStyle(Color(hex: 0x3F4249))
        }
    }
}

/// A checkbox that stays visible on the dark asphalt cards.
struct OnDarkCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isOn ? Palette.accent : Color.clear)
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(configuration.isOn ? Palette.accent : Palette.onDarkMuted, lineWidth: 1.5))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Palette.ink)
                        }
                    }
                    .padding(.top, 1)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
