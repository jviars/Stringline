import AppIntents

/// "Ask Stringline" in Shortcuts, Spotlight and Siri: opens Stringline and asks the assistant.
struct AskStringlineIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Stringline"
    static let description = IntentDescription("Ask the Stringline assistant about your jobs, or how to do something in Stringline.")
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let assistant = Assistant.current else { return .result() }
        assistant.isOpen = true
        if assistant.isRunning {
            assistant.send(question)
        } else {
            if assistant.mode == .action && !assistant.items.isEmpty { assistant.newChat() }
            assistant.send(question)
        }
        return .result()
    }
}

/// Opens the assistant panel.
struct OpenAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Stringline Assistant"
    static let description = IntentDescription("Opens Stringline with the assistant panel showing.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Assistant.current?.isOpen = true
        return .result()
    }
}

struct StringlineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskStringlineIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask Stringline", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: OpenAssistantIntent(), phrases: ["Open the \(.applicationName) assistant"],
                    shortTitle: "Open Assistant", systemImageName: "bubble.left")
    }
}
