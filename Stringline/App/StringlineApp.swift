import SwiftUI
import AppKit

@main
struct StringlineApp: App {
    @State private var store: AppStore
    @State private var assistant: Assistant
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Never restore windows saved by another build. A saved window from an older version can name a scene
        // this version doesn't have, and macOS then opens no window at all. Window sizes and positions are kept separately.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        let store: AppStore = {
            #if DEBUG
            if SelfTest.isRequested { return SelfTest.makeStore() }
            if SaveLoop.isRequested { return SaveLoop.makeStore() }
            #endif
            return AppStore()
        }()
        _store = State(initialValue: store)
        _assistant = State(initialValue: Assistant(store: store))
    }

    var body: some Scene {
        // A fixed id keeps the window's identity the same across versions and between debug and release builds.
        WindowGroup("Stringline", id: "main") {
            RootView()
                .environment(store)
                .environment(assistant)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear { appDelegate.store = store }
                #if DEBUG
                .task {
                    if SelfTest.isRequested { await SelfTest.run(store: store, assistant: assistant) }
                    if SaveLoop.isRequested { await SaveLoop.run(store: store) }
                }
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands { AppCommands(store: store, assistant: assistant) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    /// Before quitting, make sure nothing is left unsaved without the person knowing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        store.flush()
        guard store.hasUnsavedChanges, store.persistsPreferences else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let other = store.savingPaused {
            alert.messageText = "Save your changes on this Mac?"
            alert.informativeText = "Stringline is open on \(other.machineName), so \(store.pendingCount) \(store.pendingCount == 1 ? "change" : "changes") made here haven't been saved to the PavingData folder. If you quit without saving, they're kept in History on this Mac."
            alert.addButton(withTitle: "Use This Mac and Save")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                store.takeOver()
                if store.hasUnsavedChanges { return .terminateCancel }
                return .terminateNow
            case .alertSecondButtonReturn:
                store.keepUnsavedInHistory()
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
        alert.messageText = "Some changes haven't been saved yet"
        alert.informativeText = "\(store.problem ?? "The PavingData folder couldn't be reached.") If you quit now, the changes are kept in History on this Mac, and Stringline offers them back next time."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.flush()
            return store.hasUnsavedChanges ? .terminateCancel : .terminateNow
        case .alertSecondButtonReturn:
            store.keepUnsavedInHistory()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let store: AppStore
    let assistant: Assistant

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Lead…") { store.showNewLead = true }
                .keyboardShortcut("n")
                .disabled(store.needsOnboarding)
        }
        CommandGroup(after: .saveItem) {
            Button("Show Data Folder in Finder") {
                if let url = store.dataFolder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(store.dataFolder == nil)
            Button("Browse History…") { store.historyRequest = HistoryRequest() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(store.dataFolder == nil)
            Button("Import from Zoho…") { ZohoImporter.choose(store: store) }
                .disabled(store.dataFolder == nil)
            Button("Check My Data") {
                store.settingsSectionRequest = .data
                store.selection = .settings
                store.checkHealth(deep: true)
            }
            .disabled(store.dataFolder == nil)
        }
        CommandMenu("Go") {
            Button("Search…") { store.showSearch = true }.keyboardShortcut("k")
            Divider()
            Button("Today") { store.selection = .today }.keyboardShortcut("1")
            Button("Pipeline") { store.selection = .pipeline }.keyboardShortcut("2")
            Button("Measure") { store.selection = .measure }.keyboardShortcut("3")
            Button("Jobs") { store.selection = .jobs }.keyboardShortcut("4")
            Button("Schedule") { store.selection = .schedule }.keyboardShortcut("5")
            Button("Customers") { store.selection = .customers }.keyboardShortcut("6")
            Button("Invoices") { store.selection = .invoices }.keyboardShortcut("7")
            Divider()
            Button("Settings & Rates") { store.selection = .settings }.keyboardShortcut(",")
        }
        CommandMenu("Assistant") {
            Button(assistant.isOpen ? "Hide Assistant" : "Show Assistant") { assistant.toggle() }
                .keyboardShortcut("j")
                .disabled(store.needsOnboarding)
            Button(assistant.mode == .chat ? "Switch to Action" : "Switch to Chat") { assistant.toggleMode() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(store.needsOnboarding)
            Button("New Chat") { assistant.newChat() }
                .disabled(assistant.items.isEmpty)
            Divider()
            Button("Assistant Settings…") {
                store.settingsSectionRequest = .assistant
                store.selection = .settings
            }
            .disabled(store.needsOnboarding)
        }
        CommandGroup(replacing: .help) {
            Button("Ask Stringline Help…") { assistant.openForHelp() }
                .keyboardShortcut("/", modifiers: [.command, .shift])
                .disabled(store.needsOnboarding)
            Button("Learn Stringline") { store.selection = .learn }
            Button("Take the Tour") { store.startTour() }
                .disabled(store.needsOnboarding)
        }
    }
}
