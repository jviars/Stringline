import Foundation
import AppKit

extension AppStore: AssistantDataSource {
    func forecast(for day: Date) -> DayForecast? { weather.forecast(for: day) }
}

/// The assistant: a conversation with ChatGPT that knows which screen is open.
/// Chat mode only reads. Action mode proposes changes that the person applies, and can undo.
@Observable @MainActor
final class Assistant {
    struct Item: Identifiable {
        enum Kind {
            case user(String, [Attachment])
            case reply(String, sources: [Source])
            case run(RunLog)
            case notice(String, action: NoticeAction?)
            case open(Suggestion)
            case changes(UUID)
            case pastChanges(title: String, lines: [String], state: String)
        }
        let id: UUID
        var kind: Kind
        let date: Date

        init(_ kind: Kind) {
            id = UUID()
            self.kind = kind
            date = .now
        }
    }

    enum NoticeAction { case manageUsage, openSettings, switchToAction, retry, continueRun }

    struct Proposal: Identifiable {
        enum State: Equatable { case pending, applied, discarded, undone }
        let id = UUID()
        var changes: [ProposedChange]
        var state: State = .pending
        var record: UndoRecord?
        var appliedCount = 0
        var notes: [String] = []
        var impact: [EstimateImpact] = []
    }

    struct EstimateImpact: Hashable {
        let job: String
        let before: Int
        let after: Int
        let perSYAfter: Double?
    }

    let account: AIAccount
    private(set) var prefs: AssistantPrefs
    private(set) var models: [AIModel] = []
    private(set) var modelsError: String?
    var isOpen = false
    var mode: AssistantMode
    var shareScreen = true
    var composer = ""
    /// Pictures and PDFs waiting to go with the next message.
    var attachments: [Attachment] = []
    private(set) var items: [Item] = []
    private(set) var proposals: [UUID: Proposal] = [:]
    private(set) var pendingProposalID: UUID?
    private(set) var isRunning = false
    private(set) var status: String?
    private(set) var toolsUnavailable = false
    private(set) var webSearchUnavailable = false
    private(set) var attachmentsUnavailable = false
    private(set) var runItemID: UUID?
    /// Messages typed while it works; they're read at the next step.
    private(set) var steering: [String] = []
    private(set) var conversationID = UUID()
    private(set) var chats: [ChatSummary] = []
    private(set) var speakingID: UUID?

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored var services: AssistantServices?
    @ObservationIgnored let archive: ChatArchive?
    @ObservationIgnored private var history: [JSONValue] = []
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var dropped: Set<String> = []
    @ObservationIgnored private var strictTools = true
    /// nil until a form is refused: then the next one ChatGPT might take (see ToolFormat).
    @ObservationIgnored private var toolFormat: ToolFormat?
    /// How many tool entries came before web search in the last request, to tell which one an error is about.
    @ObservationIgnored private var functionToolCount = 0
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var replyItems: [String: UUID] = [:]
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var conversationStarted = Date()

    private static let prefsKey = "assistantPrefs"
    static let maxSteps = 20
    static let maxAttachments = 6

    /// The one in the running app, for Shortcuts and Siri.
    static weak var current: Assistant?

    init(store: AppStore, services: AssistantServices? = nil) {
        persists = store.persistsPreferences
        account = AIAccount(secrets: persists ? KeychainStore() : MemorySecretStore())
        var loaded = AssistantPrefs()
        if persists, let data = UserDefaults.standard.data(forKey: Self.prefsKey), let saved = try? JSONDecoder().decode(AssistantPrefs.self, from: data) {
            loaded = saved
        }
        prefs = loaded
        mode = loaded.defaultMode
        self.store = store
        self.services = services ?? AppleServices()
        archive = ChatArchive(folder: store.localRoot.appending(path: "Chats", directoryHint: .isDirectory))
        account.preferAPIKey = loaded.preferAPIKey
        account.onChange = { [weak self] in self?.connectionChanged() }
        chats = archive?.list() ?? []
        Speaker.shared.onChange = { [weak self] id in self?.speakingID = id }
        if persists { Self.current = self }
    }

    // MARK: Preferences

    func updatePrefs(_ change: (inout AssistantPrefs) -> Void) {
        var p = prefs
        change(&p)
        guard p != prefs else { return }
        prefs = p
        account.preferAPIKey = p.preferAPIKey
        if persists, let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: Self.prefsKey) }
    }

    private func connectionChanged() {
        models = []
        modelsError = nil
        toolsUnavailable = false
        webSearchUnavailable = false
        attachmentsUnavailable = false
        dropped = []
        strictTools = true
        toolFormat = nil
        if account.isReady { Task { await loadModels() } }
    }

    var showsPlanWelcome: Bool { account.billing == .chatGPTPlan && !prefs.planWelcomeSeen }

    func loadModels() async {
        guard account.isReady else { return }
        do {
            let list = try await OpenAIClient(account: account).listModels()
            models = list
            modelsError = list.isEmpty ? "No models are available to this account." : nil
            if let chosen = prefs.model, !list.contains(where: { $0.slug == chosen }), !list.isEmpty {
                updatePrefs { $0.model = nil }
            }
        } catch {
            modelsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func chosenModel() async -> String? {
        if models.isEmpty { await loadModels() }
        if let chosen = prefs.model, models.isEmpty || models.contains(where: { $0.slug == chosen }) { return chosen }
        return models.first?.slug
    }

    // MARK: Panel

    func toggle() {
        isOpen.toggle()
        if isOpen, account.isReady, models.isEmpty { Task { await loadModels() } }
    }

    /// Opens the panel ready for a question (Help › Ask Stringline Help).
    func openForHelp() {
        isOpen = true
        if items.isEmpty { mode = .chat }
        if account.isReady, models.isEmpty { Task { await loadModels() } }
    }

    func setMode(_ new: AssistantMode) {
        guard new != mode else { return }
        mode = new
        if !items.isEmpty {
            addStep(new == .action ? "Switched to Action. Changes wait for you to apply them." : "Switched to Chat. Nothing will be changed.",
                    icon: new == .action ? "bolt" : "bubble.left", standalone: true)
        }
    }

    func toggleMode() { setMode(mode == .chat ? .action : .chat) }

    var breadcrumb: String { store.map(ScreenContext.breadcrumb) ?? "" }

    /// Starters that fit the screen the person is on.
    var suggestions: [String] {
        guard let store else { return [] }
        switch store.selection {
        case .job(let id):
            switch store.jobTab {
            case .estimate:
                return store.estimates[id]?.selected == nil
                    ? ["Build an estimate from the measurements", "How do I build an estimate?"]
                    : ["Is this bid in my usual range?", "How do I add an option B?", "Write the scope of work"]
            case .measure: return ["How do I cut out an island?", "How many tons will this take?"]
            case .schedule: return ["Find the first good 3-day window", "How long is the drive there?"]
            case .invoice: return ["How do I send the invoice?", "Make the invoice"]
            default: return ["Summarize this job", "Get directions to this job"]
            }
        case .today: return ["What needs my attention today?", "Where am I?", "Any rain on job days this week?"]
        case .pipeline: return ["Which bids need a follow-up?", "How do I mark a bid lost?"]
        case .schedule: return ["How does the weather look this week?", "How do I move a crew day?"]
        case .invoices: return ["Who owes me money?", "How do I mark an invoice paid?"]
        case .customers: return ["Who are my biggest customers?", "How do I import from Zoho?", "How do I add a customer?"]
        case .settings, .crew: return ["How do I change my prices?", "Where do I set my home base?"]
        case .learn: return ["How do I measure a lot?", "What can you do?"]
        default: return ["What can you do?", "How do I add a new lead?"]
        }
    }

    // MARK: Conversations

    func newChat() {
        saveConversation()
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = nil
        runItemID = nil
        Speaker.shared.stop()
        items = []
        history = []
        replyItems = [:]
        steering = []
        attachments = []
        proposals = [:]
        pendingProposalID = nil
        refreshPreview()
        toolsUnavailable = false
        toolFormat = nil
        conversationID = UUID()
        conversationStarted = .now
        mode = prefs.defaultMode
    }

    func openChat(_ id: UUID) {
        guard let saved = archive?.load(id) else { return }
        newChat()
        conversationID = saved.id
        conversationStarted = saved.created
        mode = saved.mode
        history = saved.history
        items = saved.items.map { item -> Item in
            switch item {
            case .user(let text, let files): return Item(.user(text, files))
            case .reply(let text, let sources): return Item(.reply(text, sources: sources))
            case .run(var log):
                if log.state == .running { log.state = .stopped }
                return Item(.run(log))
            case .note(let text): return Item(.notice(text, action: nil))
            case .changes(let title, let lines, let state): return Item(.pastChanges(title: title, lines: lines, state: state))
            }
        }
        closeOpenCalls()
    }

    func deleteChat(_ id: UUID) {
        archive?.delete(id)
        chats = archive?.list() ?? []
    }

    func deleteAllChats() {
        archive?.deleteAll()
        chats = []
    }

    private func saveConversation() {
        guard prefs.keepHistory, let archive, items.contains(where: { if case .user = $0.kind { return true }; return false }) else { return }
        let saved: [SavedChat.Item] = items.compactMap { item in
            switch item.kind {
            case .user(let text, let files):
                return .user(text, files.map { var f = $0; f.dataURL = ""; return f })
            case .reply(let text, let sources): return .reply(text, sources)
            case .run(let log): return .run(log)
            case .notice(let text, _): return .note(text)
            case .open: return nil
            case .changes(let id):
                guard let p = proposals[id] else { return nil }
                let state: String = switch p.state {
                case .pending: "Not applied"
                case .applied: "Applied"
                case .undone: "Undone"
                case .discarded: "Discarded"
                }
                return .changes(title: p.changes.count == 1 ? "1 change" : "\(p.changes.count) changes",
                                lines: p.changes.map { "\($0.isOn && p.state == .applied ? "✓" : "–") \($0.title)" }, state: state)
            case .pastChanges(let title, let lines, let state): return .changes(title: title, lines: lines, state: state)
            }
        }
        let title = items.lazy.compactMap { item -> String? in
            if case .user(let text, _) = item.kind { return text }
            return nil
        }.first.map { String($0.prefix(70)) } ?? "Conversation"
        let chat = SavedChat(id: conversationID, title: title, created: conversationStarted, updated: .now, mode: mode,
                             items: saved, history: history.map(Self.withoutFiles))
        try? archive.save(chat)
        chats = archive.list()
    }

    /// Saved history keeps a note where each picture or PDF was, not the file.
    private static func withoutFiles(_ item: JSONValue) -> JSONValue {
        if item["type"]?.string == "function_call_output", let parts = item["output"]?.array {
            let text = parts.compactMap { $0["type"]?.string == "input_text" ? $0["text"]?.string : nil }.joined(separator: "\n")
            return item.setting("output", .string(text + "\n[A map picture was here. Use look_at_map again to see the lot.]"))
        }
        guard item["role"]?.string == "user", let parts = item["content"]?.array else { return item }
        return item.setting("content", .array(parts.map { part in
            switch part["type"]?.string {
            case "input_image": ["type": "input_text", "text": "[A picture was attached here]"]
            case "input_file": ["type": "input_text", "text": .string("[A PDF was attached here: \(part["filename"]?.string ?? "file")]")]
            default: part
            }
        }))
    }

    // MARK: Attachments

    /// Adds files to the next message. Returns a problem to show, if any.
    @discardableResult
    func attach(_ urls: [URL]) -> String? {
        var problems: [String] = []
        for url in urls {
            guard attachments.count < Self.maxAttachments else {
                problems.append("Up to \(Self.maxAttachments) files at a time.")
                break
            }
            do {
                attachments.append(try AttachmentMaker.make(from: url))
            } catch {
                problems.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        let message = problems.isEmpty ? nil : problems.joined(separator: " ")
        if let message { items.append(Item(.notice(message, action: nil))) }
        return message
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: Sending

    func send(_ text: String? = nil) {
        var message = (text ?? composer).trimmingCharacters(in: .whitespacesAndNewlines)
        // Attached files go with the next message, whether it was typed or picked from the suggestions.
        let files = isRunning ? [] : attachments
        if message.isEmpty && !files.isEmpty { message = files.count == 1 ? "Take a look at this." : "Take a look at these." }
        guard !message.isEmpty else { return }
        guard account.isReady else {
            items.append(Item(.notice("Connect ChatGPT or add an OpenAI API key in Settings › AI assistant first.", action: .openSettings)))
            return
        }
        if text == nil { composer = "" }
        if !isRunning { attachments = [] }
        if isRunning {
            // Steer the run that's going: it reads this at its next step.
            steering.append(String(message.prefix(4000)))
            items.append(Item(.user(message, [])))
            return
        }
        items.append(Item(.user(message, files)))
        var content: [JSONValue] = [["type": "input_text", "text": .string(String(message.prefix(8000)))]]
        content += files.map(\.inputPart)
        history.append(["role": "user", "content": .array(content)])
        start()
    }

    /// Runs the last request again (after an error).
    func retry() {
        guard !isRunning, history.contains(where: { $0["role"]?.string == "user" }) else { return }
        start()
    }

    /// Picks up after the step limit.
    func continueRun() {
        guard !isRunning else { return }
        history.append(["role": "developer", "content": "The owner pressed Continue. Carry on where you left off."])
        start()
    }

    /// Asks for the last answer again.
    func regenerate() {
        guard !isRunning, let lastUser = history.lastIndex(where: { $0["role"]?.string == "user" }),
              let lastUserItem = items.lastIndex(where: { if case .user = $0.kind { return true }; return false }) else { return }
        dropProposals(in: items[(lastUserItem + 1)...])
        items.removeSubrange((lastUserItem + 1)...)
        history.removeSubrange((lastUser + 1)...)
        start()
    }

    /// Puts the last message back in the box to change it.
    func editLast() {
        guard !isRunning, let lastUser = history.lastIndex(where: { $0["role"]?.string == "user" }),
              let lastUserItem = items.lastIndex(where: { if case .user = $0.kind { return true }; return false }),
              case .user(let text, let files) = items[lastUserItem].kind else { return }
        dropProposals(in: items[lastUserItem...])
        items.removeSubrange(lastUserItem...)
        history.removeSubrange(lastUser...)
        composer = text
        attachments = files.filter(\.hasData)
    }

    private func dropProposals(in removed: ArraySlice<Item>) {
        for item in removed {
            if case .changes(let id) = item.kind, proposals[id]?.state == .pending {
                proposals[id] = nil
                if pendingProposalID == id { pendingProposalID = nil }
            }
        }
        refreshPreview()
    }

    func stop() {
        runTask?.cancel()
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Markdown.plain(text), forType: .string)
    }

    func readAloud(_ text: String, id: UUID) {
        Speaker.shared.toggle(Markdown.plain(text), id: id)
    }

    private func start() {
        runTask = Task { [weak self] in await self?.run() }
    }

    private var pendingChanges: [ProposedChange] {
        pendingProposalID.flatMap { proposals[$0] }.map(\.changes) ?? []
    }

    // MARK: The run

    private func run() async {
        guard let store else { return }
        let conversation = conversationID
        isRunning = true
        status = "Thinking…"
        replyItems = [:]
        let runMode = mode
        let runStart = items.count
        let log = Item(.run(RunLog()))
        items.append(log)
        runItemID = log.id
        let runner = ToolRunner(base: store, mode: runMode, areas: prefs.areas, shareContact: prefs.shareContact,
                                pending: pendingChanges.filter(\.isOn).flatMap(\.ops), services: services,
                                context: ScreenContext.runnerContext(store, panelOpen: isOpen))
        var ending: RunLog.State = .done
        defer {
            if conversation == conversationID {
                collect(from: runner)
                closeOpenCalls()
                compactHistory()
                if ending == .done, !showedSomething(since: runStart) {
                    // Never end in silence: say so, and offer to try again.
                    items.append(Item(.notice("ChatGPT finished without an answer or a change. Try again, or say it a different way.", action: .retry)))
                }
                finishRunLog(ending)
                isRunning = false
                status = nil
                runTask = nil
                runItemID = nil
                saveConversation()
                if ending == .done {
                    let waiting = pendingChanges.count
                    Notifier.finished(waiting > 0 ? "\(waiting == 1 ? "1 change is" : "\(waiting) changes are") waiting for you to apply." : "Your answer is ready.")
                }
            }
        }
        do {
            guard let model = await chosenModel() else {
                throw OpenAIError(status: nil, code: nil, message: modelsError ?? "No model is available to this account yet.", param: nil)
            }
            var steps = 0
            while true {
                steps += 1
                guard steps <= Self.maxSteps else {
                    items.append(Item(.notice("I've taken \(Self.maxSteps) steps, so I paused here. Press Continue to keep going.", action: .continueRun)))
                    ending = .stopped
                    break
                }
                try Task.checkCancellation()
                let response = try await request(model: model, mode: runMode)
                guard conversation == conversationID else { return }
                attachSources(response)
                record(response.output)
                if case .incomplete(let reason) = response.status {
                    items.append(Item(.notice("The reply was cut short (\(reason.replacingOccurrences(of: "_", with: " "))).", action: .retry)))
                }
                let calls = response.functionCalls
                if calls.isEmpty {
                    if takeSteering() { continue }
                    break
                }
                for call in calls {
                    try Task.checkCancellation()
                    let name = call["name"]?.string ?? ""
                    status = Self.statusText(for: name)
                    runner.context = ScreenContext.runnerContext(store, panelOpen: isOpen)
                    runner.picturesAllowed = !attachmentsUnavailable
                    let outcome = await runner.runAsync(name: name, arguments: call["arguments"]?.string ?? "{}")
                    guard conversation == conversationID else { return }
                    show(outcome)
                    let text = String(outcome.output.compactString.prefix(16_000))
                    // A map picture goes back with the result, so the model can see what it's drawing on.
                    let output: JSONValue = outcome.image.map { picture in
                        .array([["type": "input_text", "text": .string(text)], ["type": "input_image", "image_url": .string(picture), "detail": "high"]])
                    } ?? .string(text)
                    history.append(["type": "function_call_output", "call_id": .string(call["call_id"]?.string ?? ""), "output": output])
                }
                collect(from: runner)
                _ = takeSteering()
                status = "Thinking…"
            }
        } catch is CancellationError {
            ending = .stopped
        } catch let error as URLError where error.code == .cancelled {
            ending = .stopped
        } catch let error as OpenAIError {
            ending = .failed
            if conversation == conversationID { report(error) }
        } catch {
            ending = .failed
            if conversation == conversationID {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                items.append(Item(.notice(text, action: account.isReady ? .retry : .openSettings)))
            }
        }
    }

    /// True if a run put anything in the chat: words, a step, a change, a button or a notice.
    private func showedSomething(since start: Int) -> Bool {
        items.dropFirst(start).contains { item in
            switch item.kind {
            case .reply(let text, _): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .run(let log): !log.steps.isEmpty
            case .notice, .changes, .open, .pastChanges: true
            case .user: false
            }
        }
    }

    /// Hands messages typed during the run to the model. True if there were any.
    private func takeSteering() -> Bool {
        guard !steering.isEmpty else { return false }
        for text in steering {
            history.append(["role": "user", "content": .string("(Added while you were working) \(text)")])
        }
        steering = []
        return true
    }

    static func statusText(for tool: String) -> String {
        switch tool {
        case "search": "Searching…"
        case "get_job", "get_customer": "Looking it up…"
        case "get_estimate", "compare_past_jobs": "Reading the estimate…"
        case "get_schedule": "Checking the schedule…"
        case "get_weather": "Checking the forecast…"
        case "get_rates": "Reading your rates…"
        case "get_invoices": "Reading invoices…"
        case "search_help", "get_help_article": "Looking in the help…"
        case "open_screen", "show_me": "Opening…"
        case "point_at": "Pointing…"
        case "drive_time", "find_place", "open_in_maps": "Asking Apple Maps…"
        default: "Lining up a change…"
        }
    }

    private func request(model: String, mode: AssistantMode) async throws -> ResponseAccumulator {
        var attempt = 0
        while true {
            attempt += 1
            let body = makeBody(model: model, mode: mode)
            do {
                let response = try await OpenAIClient(account: account).stream(body) { update in
                    self.apply(update)
                }
                if case .failed(let error) = response.status { throw error }
                return response
            } catch let error as OpenAIError {
                dropStreamedReplies()
                let fixable = error.kind == .unsupported || (error.kind == .other && error.status == 400)
                switch error.kind {
                case _ where fixable && attempt <= 4 && (adapt(to: error) || adaptToRejectedItems(error)):
                    continue
                case .tryLater where attempt <= 2:
                    status = "ChatGPT is busy. Trying again…"
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                    continue
                case .signInEnded where attempt == 1:
                    if await account.recoverFromUnauthorized() { continue }
                    throw error
                default:
                    throw error
                }
            }
        }
    }

    private var usesWebSearch: Bool { prefs.webSearch && !webSearchUnavailable && !toolsUnavailable }

    /// ChatGPT plan requests take function tools in namespaces; API-key requests take the plain list.
    private var currentToolFormat: ToolFormat { toolFormat ?? (account.billing == .chatGPTPlan ? .namespaces : .flat) }

    private func makeBody(model: String, mode: AssistantMode) -> JSONValue {
        var input = inputItems()
        var body: [String: JSONValue] = [
            "model": .string(model),
            "instructions": .string(AssistantPrompt.instructions(mode: mode, today: Date(), company: store?.settings.company.name ?? "",
                                                                 areas: prefs.areas, toolsAvailable: !toolsUnavailable)),
            "store": false,
            "stream": true,
        ]
        if !dropped.contains("include") { body["include"] = ["reasoning.encrypted_content"] }
        if !toolsUnavailable {
            let specs = ToolRunner.specs(mode: mode, areas: prefs.areas)
            let format = currentToolFormat
            var tools = format == .additionalTools ? [] : ToolFormat.tools(specs, format: format, strict: strictTools)
            functionToolCount = tools.count
            if format == .additionalTools {
                input.insert(["type": "additional_tools", "role": "developer",
                              "tools": .array(ToolFormat.tools(specs, format: .namespaces, strict: strictTools))], at: 0)
            }
            if usesWebSearch { tools.append(["type": "web_search"]) }
            if !tools.isEmpty { body["tools"] = .array(tools) }
            if !dropped.contains("tool_choice") { body["tool_choice"] = "auto" }
            if !dropped.contains("parallel_tool_calls") { body["parallel_tool_calls"] = false }
        }
        body["input"] = .array(input)
        return .object(body)
    }

    /// The tool entry an error points at ("tools[2].type" is 2).
    private static func toolIndex(_ param: String) -> Int? {
        guard let open = param.range(of: "tools["), let close = param[open.upperBound...].firstIndex(of: "]") else { return nil }
        return Int(param[open.upperBound..<close])
    }

    /// Moves to the next way of sending tools. False when there isn't one left.
    private func nextToolFormat() -> Bool {
        let chain: [ToolFormat] = account.billing == .chatGPTPlan ? [.namespaces, .additionalTools, .flat] : [.flat]
        guard let i = chain.firstIndex(of: currentToolFormat), i + 1 < chain.count else { return false }
        toolFormat = chain[i + 1]
        return true
    }

    /// The conversation, with a fresh description of the screen just before the latest message.
    private func inputItems() -> [JSONValue] {
        guard let store else { return history }
        let screen = shareScreen
            ? AssistantPrompt.screenMessage(ScreenContext.snapshot(store, shareContact: prefs.shareContact, pending: pendingChanges),
                                            breadcrumb: ScreenContext.breadcrumb(store))
            : AssistantPrompt.hiddenScreenMessage
        var items = history
        if let last = items.lastIndex(where: { $0["role"]?.string == "user" }) {
            items.insert(screen, at: last)
        } else {
            items.append(screen)
        }
        return items
    }

    /// ChatGPT said part of the request isn't allowed: leave that part out and try again.
    private func adapt(to error: OpenAIError) -> Bool {
        let param = (error.param ?? "").lowercased()
        let text = (error.message ?? "").lowercased()
        let mentions = { (word: String) in param.contains(word) || text.contains(word) }
        let index = Self.toolIndex(param)
        if mentions("web_search") || (usesWebSearch && index != nil && index == functionToolCount) {
            guard usesWebSearch else { return false }
            webSearchUnavailable = true
            items.append(Item(.notice("Web search isn't available on this account, so I'll answer without it.", action: nil)))
            return true
        }
        if mentions("input_image") || mentions("input_file") || mentions("image") || mentions("file_data") {
            guard history.contains(where: Self.hasFiles) else { return false }
            history = history.map(Self.withoutFiles)
            attachmentsUnavailable = true
            items.append(Item(.notice("ChatGPT didn't accept a picture from Stringline, so I'm going on without it. Pictures (attachments and the map view) work with an OpenAI API key.", action: nil)))
            return true
        }
        if param.contains("strict") {
            guard strictTools else { return false }
            strictTools = false
        } else if param.contains("tool_choice") {
            guard !dropped.contains("tool_choice") else { return false }
            dropped.insert("tool_choice")
        } else if param.contains("parallel_tool_calls") {
            guard !dropped.contains("parallel_tool_calls") else { return false }
            dropped.insert("parallel_tool_calls")
        } else if mentions("namespace") || mentions("additional_tools") || param.contains("tools") || text.contains("tools") {
            if nextToolFormat() { return true }
            guard !toolsUnavailable else { return false }
            toolsUnavailable = true
            items.append(Item(.notice("ChatGPT doesn't let apps use tools on this account, so I can only answer from what's on your screen. Looking things up and making changes need an OpenAI API key (Settings › AI assistant).", action: .openSettings)))
        } else if param.contains("include") || param.contains("reasoning") || !dropped.contains("include") {
            guard !dropped.contains("include") else { return false }
            dropped.insert("include")
            history.removeAll { $0["type"]?.string == "reasoning" }
        } else {
            return false
        }
        return true
    }

    private static func hasFiles(_ item: JSONValue) -> Bool {
        ((item["content"]?.array ?? []) + (item["output"]?.array ?? [])).contains { ["input_image", "input_file"].contains($0["type"]?.string ?? "") }
    }

    /// A 400 about the conversation's own items: send them back in their plainest form.
    private func adaptToRejectedItems(_ error: OpenAIError) -> Bool {
        let text = (error.message ?? "").lowercased()
        guard text.contains("item") || text.contains("reasoning"), !dropped.contains("plain-items") else { return false }
        dropped.insert("plain-items")
        dropped.insert("include")
        history = history.compactMap { item in
            switch item["type"]?.string {
            case "reasoning", "web_search_call": return nil
            case "message", "function_call": return item.setting("id", nil).setting("status", nil)
            default: return item
            }
        }
        return true
    }

    // MARK: Streaming into the chat

    private func apply(_ update: ResponseAccumulator.Update) {
        switch update {
        case .textDelta(let itemID, let delta):
            if let chatID = replyItems[itemID], let i = items.firstIndex(where: { $0.id == chatID }), case .reply(let text, let sources) = items[i].kind {
                items[i].kind = .reply(text + delta, sources: sources)
            } else {
                let item = Item(.reply(delta, sources: []))
                replyItems[itemID] = item.id
                items.append(item)
            }
            status = nil
        case .itemStarted(let item):
            switch item["type"]?.string {
            case "function_call": if let name = item["name"]?.string { status = Self.statusText(for: name) }
            case "web_search_call": status = "Searching the web…"
            default: break
            }
        case .itemDone:
            break
        }
    }

    private func attachSources(_ response: ResponseAccumulator) {
        let sources = Source.citations(in: response.output)
        if response.output.contains(where: { $0["type"]?.string == "web_search_call" }) {
            addStep("Searched the web", icon: "globe")
        }
        guard !sources.isEmpty else { return }
        for item in response.output where item["type"]?.string == "message" {
            guard let id = item["id"]?.string, let chatID = replyItems[id], let i = items.firstIndex(where: { $0.id == chatID }),
                  case .reply(let text, _) = items[i].kind else { continue }
            items[i].kind = .reply(text, sources: sources)
        }
    }

    /// Removes reply text from a request that's about to be retried.
    private func dropStreamedReplies() {
        let ids = Set(replyItems.values)
        items.removeAll { ids.contains($0.id) }
        replyItems = [:]
    }

    /// Adds a response's output to the conversation, as the stateless Responses API expects.
    private func record(_ output: [JSONValue]) {
        replyItems = [:]
        for item in output {
            switch item["type"]?.string {
            case "reasoning":
                if !dropped.contains("include"), item["encrypted_content"]?.string != nil { history.append(item) }
            case "message", "function_call":
                history.append(dropped.contains("plain-items") ? item.setting("id", nil).setting("status", nil) : item)
            case "web_search_call":
                if !dropped.contains("plain-items") { history.append(item) }
            default:
                break
            }
        }
    }

    /// After a stop, every function call needs an answer or the next request is refused.
    private func closeOpenCalls() {
        let answered = Set(history.compactMap { $0["type"]?.string == "function_call_output" ? $0["call_id"]?.string : nil })
        for item in history where item["type"]?.string == "function_call" {
            guard let id = item["call_id"]?.string, !answered.contains(id) else { continue }
            history.append(["type": "function_call_output", "call_id": .string(id), "output": "{\"error\":\"Stopped by the owner before this ran.\"}"])
        }
    }

    /// Keeps the last dozen exchanges, cut at a message from the person, and only the newest attachments.
    private func compactHistory() {
        let userIndexes = history.indices.filter { history[$0]["role"]?.string == "user" }
        if userIndexes.count > 12 {
            history.removeFirst(userIndexes[userIndexes.count - 12])
        }
        let withFiles = history.indices.filter { Self.hasFiles(history[$0]) }
        for i in withFiles.dropLast(2) { history[i] = Self.withoutFiles(history[i]) }
    }

    // MARK: Progress card

    private func addStep(_ text: String, icon: String, failed: Bool = false, standalone: Bool = false) {
        let step = RunStep(text: text, icon: icon, state: failed ? .failed : .done)
        if !standalone, let id = runItemID, let i = items.firstIndex(where: { $0.id == id }), case .run(var log) = items[i].kind {
            log.steps.append(step)
            items[i].kind = .run(log)
        } else {
            var log = RunLog(steps: [step], state: .done)
            log.ended = .now
            items.append(Item(.run(log)))
        }
    }

    private func finishRunLog(_ state: RunLog.State) {
        guard let id = runItemID, let i = items.firstIndex(where: { $0.id == id }), case .run(var log) = items[i].kind else { return }
        log.state = state
        log.ended = .now
        if log.steps.isEmpty && state == .done {
            items.remove(at: i)
        } else {
            items[i].kind = .run(log)
        }
    }

    private func show(_ outcome: ToolOutcome) {
        addStep(outcome.activity, icon: outcome.icon, failed: outcome.isError)
        if let destination = outcome.navigate { go(to: destination) }
        if let spot = outcome.spotlight { spotlight(spot) }
        if let external = outcome.external { perform(external) }
        if let suggestion = outcome.suggestion { items.append(Item(.open(suggestion))) }
        if !outcome.highlight.isEmpty { highlight(Set(outcome.highlight)) }
    }

    func use(_ suggestion: Suggestion) {
        if let destination = suggestion.destination { go(to: destination) }
        if let spot = suggestion.spot { spotlight(spot, after: suggestion.destination == nil ? 0 : 0.6) }
        if let external = suggestion.external { perform(external) }
    }

    func go(to destination: Destination) {
        guard let store else { return }
        switch destination {
        case .today: store.selection = .today
        case .pipeline: store.selection = .pipeline
        case .measure: store.selection = .measure
        case .jobs: store.selection = .jobs
        case .invoices: store.selection = .invoices
        case .learn: store.selection = .learn
        case .settings: store.selection = .settings
        case .settingsSection(let section):
            store.settingsSectionRequest = SettingsSection(rawValue: section) ?? .rates
            store.selection = .settings
        case .schedule(let week):
            store.selection = .schedule
            store.scheduleWeekRequest = week
        case .customers(let id):
            store.selection = .customers
            store.customerRequest = id
        case .job(let id, let tab):
            guard store.job(id) != nil else { return }
            store.openJob(id, tab: JobTab(rawValue: tab) ?? .overview)
        }
    }

    /// Opens Apple Maps. (Test hook: `openMaps`.)
    @ObservationIgnored var openMaps: (ExternalAction) -> Void = { action in
        switch action {
        case .maps(let name, let address, let lat, let lon, let directions):
            let coordinate = lat.flatMap { la in lon.map { Coordinate(lat: la, lon: $0) } }
            MapsLink.open(name: name, address: address, coordinate: coordinate, directions: directions)
        }
    }

    private func perform(_ action: ExternalAction) { openMaps(action) }

    func spotlight(_ spot: String, after delay: Double = 0.5) {
        guard let store else { return }
        store.assistantSpotlight = nil
        Task { [weak store] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            store?.assistantSpotlight = spot
        }
    }

    func highlight(_ ids: Set<UUID>, seconds: Double = 8) {
        guard let store, !ids.isEmpty else { return }
        store.assistantHighlights = ids
        highlightTask?.cancel()
        highlightTask = Task { [weak store] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let store, store.assistantHighlights == ids else { return }
            store.assistantHighlights = []
        }
    }

    private func report(_ error: OpenAIError) {
        let text = error.errorDescription ?? "Something went wrong."
        switch error.kind {
        case .usageLimit: items.append(Item(.notice(text, action: account.billing == .chatGPTPlan ? .manageUsage : nil)))
        case .signInEnded, .badKey, .notEligible: items.append(Item(.notice(text, action: .openSettings)))
        default: items.append(Item(.notice(text, action: .retry)))
        }
    }

    // MARK: Proposals

    /// Moves what a run proposed onto the change card (one card while changes are waiting).
    private func collect(from runner: ToolRunner) {
        let new = runner.takeProposed()
        guard !new.isEmpty else { return }
        var proposal = pendingProposalID.flatMap { proposals[$0] } ?? Proposal(changes: [])
        proposal.changes += new
        proposals[proposal.id] = proposal
        pendingProposalID = proposal.id
        items.removeAll { if case .changes(let id) = $0.kind { return id == proposal.id }; return false }
        items.append(Item(.changes(proposal.id)))
        refreshPreview()
    }

    /// Shapes on the change card, drawn dashed on the Measure map so the owner sees them before applying.
    private func refreshPreview() {
        guard let store else { return }
        var preview: [UUID: [TakeoffShape]] = [:]
        if let id = pendingProposalID, let p = proposals[id], p.state == .pending {
            let state = DraftState.replay(p.changes.filter(\.isOn).flatMap(\.ops), base: store).state
            for (jobID, t) in state.takeoffs {
                let current = store.takeoffs[jobID]?.shapes ?? []
                let changed = t.shapes.filter { shape in current.first { $0.id == shape.id } != shape }
                if !changed.isEmpty { preview[jobID] = changed }
            }
        }
        if store.assistantPreview != preview { store.assistantPreview = preview }
    }

    func setChange(_ changeID: UUID, on: Bool, in proposalID: UUID) {
        guard var p = proposals[proposalID], p.state == .pending, let i = p.changes.firstIndex(where: { $0.id == changeID }) else { return }
        p.changes[i].isOn = on
        proposals[proposalID] = p
        refreshPreview()
    }

    /// Bid price before and after the ticked changes, for each estimate they touch.
    func impact(of proposalID: UUID) -> [EstimateImpact] {
        guard let store, let p = proposals[proposalID] else { return [] }
        if p.state != .pending { return p.impact }
        let ops = p.changes.filter(\.isOn).flatMap(\.ops)
        let (draft, _) = DraftState.replay(ops, base: store)
        return draft.estimates.compactMap { id, estimate -> EstimateImpact? in
            guard let after = estimate.selected, !after.items.isEmpty else { return nil }
            let before = store.estimates[id]?.options.first { $0.id == after.id }?.breakdown.priceCents ?? 0
            let name = draft.job(id, store)?.name ?? "Estimate"
            let sy = Estimator.summary(draft.takeoff(id, store), factors: draft.currentRates(store).factors).billableSY
            let perSY = sy > 0 ? Double(after.breakdown.priceCents) / 100 / sy : nil
            return EstimateImpact(job: name, before: before, after: after.breakdown.priceCents, perSYAfter: perSY)
        }
        .filter { $0.before != $0.after }
        .sorted { $0.job < $1.job }
    }

    func apply(_ proposalID: UUID) {
        guard let store, var p = proposals[proposalID], p.state == .pending, !isRunning else { return }
        let ticked = p.changes.filter(\.isOn)
        guard !ticked.isEmpty else { return }
        let priceImpact = impact(of: proposalID)
        switch AssistantCommit.commit(ticked, store: store) {
        case .failure(let refusal):
            items.append(Item(.notice(refusal.message, action: nil)))
        case .success(let outcome):
            p.state = .applied
            p.record = outcome.record
            p.appliedCount = outcome.applied.count
            p.notes = outcome.skipped
            p.impact = priceImpact
            proposals[proposalID] = p
            pendingProposalID = nil
            refreshPreview()
            registerUndo(proposalID)
            highlight(outcome.highlights, seconds: 10)
            var note = "The owner applied: " + outcome.applied.map(\.title).joined(separator: "; ") + "."
            let unticked = p.changes.filter { !$0.isOn }.map(\.title)
            if !unticked.isEmpty { note += " Left out (unticked): " + unticked.joined(separator: "; ") + "." }
            if !outcome.skipped.isEmpty { note += " Couldn't apply: " + outcome.skipped.joined(separator: "; ") + "." }
            history.append(["role": "developer", "content": .string(note)])
            saveConversation()
        }
    }

    func discard(_ proposalID: UUID) {
        guard var p = proposals[proposalID], p.state == .pending, !isRunning else { return }
        p.state = .discarded
        proposals[proposalID] = p
        pendingProposalID = nil
        refreshPreview()
        history.append(["role": "developer", "content": "The owner discarded the proposed changes. Nothing was saved."])
        saveConversation()
    }

    /// Undo from the card.
    func undo(_ proposalID: UUID) {
        performUndo(proposalID)
        undoManager?.removeAllActions(withTarget: self)
    }

    private func performUndo(_ proposalID: UUID) {
        guard let store, var p = proposals[proposalID], p.state == .applied, let record = p.record else { return }
        let kept = AssistantCommit.undo(record, store: store)
        p.state = .undone
        p.notes = kept
        proposals[proposalID] = p
        history.append(["role": "developer", "content": .string("The owner undid the changes they had applied\(kept.isEmpty ? "" : ", except: " + kept.joined(separator: " "))")])
        saveConversation()
    }

    private func performRedo(_ proposalID: UUID) {
        guard let store, var p = proposals[proposalID], p.state == .undone, let record = p.record else { return }
        let result = AssistantCommit.redo(record, store: store)
        p.state = .applied
        p.record = result.record
        p.notes = result.kept
        proposals[proposalID] = p
        history.append(["role": "developer", "content": "The owner redid the changes."])
        saveConversation()
    }

    /// Edit › Undo (⌘Z) and Redo (⇧⌘Z) work on the assistant's applied changes too.
    private func registerUndo(_ proposalID: UUID) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.performUndo(proposalID)
                target.undoManager?.registerUndo(withTarget: target) { again in
                    MainActor.assumeIsolated {
                        again.performRedo(proposalID)
                        again.registerUndo(proposalID)
                    }
                }
                target.undoManager?.setActionName("Assistant Changes")
            }
        }
        manager.setActionName("Assistant Changes")
    }
}
