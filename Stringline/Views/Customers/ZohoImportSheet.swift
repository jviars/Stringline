import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Picks and reads Zoho's exports, and applies an import as one undoable step.
@MainActor
enum ZohoImporter {
    /// File › Import from Zoho…, the Customers screen and Settings › Data & backups all start here.
    static func choose(store: AppStore) {
        let urls = pick()
        guard !urls.isEmpty else { return }
        store.zohoImport = load(urls)
    }

    static func pick() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose the files you exported from Zoho"
        panel.prompt = "Choose"
        panel.message = "Pick all of them at once: Accounts, Contacts, Deals, Leads and Notes (CSV), or the zip Zoho downloaded. You'll see what happens before anything changes."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .zip, .spreadsheet]
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Reads CSV files, and the CSV files inside a zip. Spreadsheets are turned away with what to do instead.
    static func load(_ urls: [URL], into session: ZohoImport.Session? = nil) -> ZohoImport.Session {
        var session = session ?? ZohoImport.Session(tables: [])
        for url in urls {
            let name = url.lastPathComponent
            switch url.pathExtension.lowercased() {
            case "zip":
                let inside = unzip(url)
                if inside.isEmpty { session.problems.append("\(name) has no CSV files inside.") }
                session.tables += inside.map { ZohoImport.table(fileName: "\(name) › \($0.name)", data: $0.data) }
            case "xlsx", "xls", "numbers":
                session.problems.append("\(name) is a spreadsheet. In Zoho, choose CSV when you export, then pick that file.")
            default:
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 200_000_000,
                      let data = try? Data(contentsOf: url) else {
                    session.problems.append("\(name) couldn't be read.")
                    continue
                }
                session.tables.append(ZohoImport.table(fileName: name, data: data))
            }
        }
        return session
    }

    private static func unzip(_ zip: URL) -> [(name: String, data: Data)] {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "StringlineZoho-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: folder) }
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return [] }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        guard (try? ditto.run()) != nil else { return [] }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, Data)] = []
        for case let file as URL in walker where file.pathExtension.lowercased() == "csv" && !file.path.contains("__MACOSX") {
            if let data = try? Data(contentsOf: file) { out.append((file.lastPathComponent, data)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// One import's place in Edit › Undo, so undoing it never touches anything else.
    final class UndoTarget {}

    struct Done {
        let customers: Int
        let filled: Int
        let jobs: Int
        let notes: [String]
        let record: UndoRecord
        let target: UndoTarget
    }

    /// Applies the plan through the same path as the assistant's changes: every file it touches has to be
    /// saveable, and the whole import can be undone with ⌘Z.
    static func apply(_ plan: ZohoImport.Plan, store: AppStore, undoManager: UndoManager?) -> Result<Done, AssistantCommit.Refusal> {
        switch AssistantCommit.commit(plan.changes, store: store) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let outcome):
            let target = UndoTarget()
            registerUndo(outcome.record, store: store, manager: undoManager, target: target)
            let done = Done(customers: outcome.record.createdCustomers.count, filled: outcome.record.customers.count,
                            jobs: outcome.record.createdJobs.count, notes: outcome.skipped, record: outcome.record, target: target)
            store.toast = "Imported \(count(done.customers, "customer")) and \(count(done.jobs, "job")) from Zoho. ⌘Z undoes it."
            store.flush()
            return .success(done)
        }
    }

    static func undo(_ done: Done, store: AppStore, undoManager: UndoManager?) -> [String] {
        undoManager?.removeAllActions(withTarget: done.target)
        let kept = AssistantCommit.undo(done.record, store: store)
        store.flush()
        return kept
    }

    private static func registerUndo(_ record: UndoRecord, store: AppStore, manager: UndoManager?, target: UndoTarget) {
        guard let manager else { return }
        // The undo manager doesn't keep its targets alive, and the import window that made this one may be closed
        // by the time ⌘Z is pressed. Each action holds its own target, so it's always there to undo against.
        manager.registerUndo(withTarget: target) { [target] _ in
            MainActor.assumeIsolated {
                let kept = AssistantCommit.undo(record, store: store)
                store.toast = kept.isEmpty ? "Zoho import undone." : "Zoho import undone, except: " + kept.joined(separator: " ")
                manager.registerUndo(withTarget: target) { [target] _ in
                    MainActor.assumeIsolated {
                        let again = AssistantCommit.redo(record, store: store)
                        registerUndo(again.record, store: store, manager: manager, target: target)
                    }
                }
                manager.setActionName("Import from Zoho")
            }
        }
        manager.setActionName("Import from Zoho")
    }

    static func count(_ n: Int, _ word: String) -> String { "\(Fmt.number(Double(n))) \(word)\(n == 1 ? "" : "s")" }
}

/// The Import from Zoho window: what was found in the files, what will be added, and one button to do it.
struct ZohoImportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let undoManager: UndoManager?
    @State private var session: ZohoImport.Session
    @State private var options = ZohoImport.Options()
    @State private var plan = ZohoImport.Plan()
    @State private var done: ZohoImporter.Done?
    @State private var kept: [String]?
    @State private var error: String?
    @State private var showSkipped = false

    init(session: ZohoImport.Session, undoManager: UndoManager?) {
        _session = State(initialValue: session)
        self.undoManager = undoManager
    }

    private var hasLeads: Bool { session.tables.contains { $0.kind == .leads } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "square.and.arrow.down.on.square", tone: .info, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import from Zoho").font(.display(26))
                    Text("Customers and deals from the files Zoho exported. Nothing changes until you press Import.")
                        .font(.ui(13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let done {
                finished(done)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        files
                        summary
                        preview
                        if hasLeads || plan.matched > 0 { optionsCard }
                    }
                }
                .frame(maxHeight: 460)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.ui(12.5)).foregroundStyle(Palette.noGoInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Add more files…") {
                        let urls = ZohoImporter.pick()
                        if !urls.isEmpty { session = ZohoImporter.load(urls, into: session) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(importLabel) { runImport() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(plan.isEmpty)
                }
            }
        }
        .padding(28)
        .frame(width: 660)
        .onAppear(perform: replan)
        .onChange(of: options) { _, _ in replan() }
        .onChange(of: session.tables) { _, _ in replan() }
    }

    private var importLabel: String {
        if plan.isEmpty { return "Nothing to import" }
        var parts: [String] = []
        if !plan.newCustomers.isEmpty { parts.append(ZohoImporter.count(plan.newCustomers.count, "customer")) }
        if !plan.newJobs.isEmpty { parts.append(ZohoImporter.count(plan.newJobs.count, "job")) }
        return parts.isEmpty ? "Import" : "Import " + parts.joined(separator: " and ")
    }

    private func replan() {
        plan = ZohoImport.plan(session.tables, customers: store.customers, jobs: store.jobs, options: options)
        error = nil
    }

    private func runImport() {
        switch ZohoImporter.apply(plan, store: store, undoManager: undoManager) {
        case .success(let result): done = result
        case .failure(let refusal): error = refusal.message
        }
    }

    // MARK: Pieces

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FILES").font(.eyebrow).tracking(0.8).foregroundStyle(Palette.tertiary)
            ForEach(session.tables) { table in
                HStack(spacing: 10) {
                    Image(systemName: icon(table.kind)).frame(width: 18).foregroundStyle(table.kind == .unknown ? Palette.watchInk : Palette.secondary)
                    Text(table.fileName).font(.ui(13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(table.kind == .unknown ? table.kind.label : "\(table.kind.label) · \(ZohoImporter.count(table.rows.count, "row"))")
                        .font(.ui(12.5)).foregroundStyle(table.kind == .unknown ? Palette.watchInk : Palette.secondary)
                }
            }
            ForEach(session.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.ui(12.5)).foregroundStyle(Palette.watchInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT WILL HAPPEN").font(.eyebrow).tracking(0.8).foregroundStyle(Palette.tertiary)
            line("person.crop.circle.badge.plus", "\(ZohoImporter.count(plan.newCustomers.count, "new customer"))")
            if plan.matched > 0 {
                line("person.2", options.fillMatches
                     ? "\(ZohoImporter.count(plan.matched, "customer")) you already have: \(plan.filled.count) \(plan.filled.count == 1 ? "gets" : "get") blank fields filled in. Nothing is overwritten."
                     : "\(ZohoImporter.count(plan.matched, "customer")) you already have are left as they are.")
            }
            line("rectangle.split.3x1", plan.newJobs.isEmpty ? "No new jobs"
                 : "\(ZohoImporter.count(plan.newJobs.count, "new job")): " + plan.jobsByStage.map { "\($0.1) \($0.0.label)" }.joined(separator: " · "))
            let noAddress = plan.newJobs.filter { $0.address.isEmpty }.count
            if noAddress > 0 {
                line("mappin.slash", "\(ZohoImporter.count(noAddress, "job")) without a site address. Add one before measuring.", tone: Palette.watchInk)
            }
            if plan.notes > 0 { line("note.text", "\(ZohoImporter.count(plan.notes, "note")) added to customers and jobs") }
            if !plan.skipped.isEmpty {
                Button {
                    showSkipped.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showSkipped ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
                        Text("\(ZohoImporter.count(plan.skipped.count, "row")) skipped").font(.ui(13, weight: .semibold))
                    }
                    .foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
                if showSkipped {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(plan.skipped.prefix(60).enumerated()), id: \.offset) { _, reason in
                            Text(reason).font(.ui(12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if plan.skipped.count > 60 { Text("…and \(plan.skipped.count - 60) more").font(.ui(12)).foregroundStyle(Palette.tertiary) }
                    }
                    .padding(.leading, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    @ViewBuilder
    private var preview: some View {
        if !plan.newCustomers.isEmpty || !plan.newJobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("A FEW OF THEM").font(.eyebrow).tracking(0.8).foregroundStyle(Palette.tertiary)
                ForEach(plan.newCustomers.prefix(4)) { c in
                    previewRow("person", c.name, [c.contact, c.phone, c.email].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                ForEach(plan.newJobs.prefix(4)) { j in
                    let customer = plan.newCustomers.first { $0.id == j.customerID }?.name ?? store.customer(j.customerID)?.name
                    previewRow("rectangle.split.3x1", j.name, [j.stage.label, customer].compactMap { $0 }.joined(separator: " · "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 16)
        }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasLeads {
                Toggle(isOn: $options.leadJobs) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Make a job at the Lead stage for each Zoho lead").font(.ui(13, weight: .semibold))
                        Text("Leads marked junk, lost or not qualified don't get one.").font(.ui(12)).foregroundStyle(Palette.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            if plan.matched > 0 || !options.fillMatches {
                Toggle(isOn: $options.fillMatches) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fill in blanks on customers you already have").font(.ui(13, weight: .semibold))
                        Text("Matched by email, phone or name. Their own details are never replaced.").font(.ui(12)).foregroundStyle(Palette.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    private func finished(_ done: ZohoImporter.Done) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let kept {
                Label(kept.isEmpty ? "The import was undone." : "The import was undone, except: " + kept.joined(separator: " "),
                      systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.ui(14, weight: .semibold)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Imported \(ZohoImporter.count(done.customers, "customer")) and \(ZohoImporter.count(done.jobs, "job")).", systemImage: "checkmark.circle.fill")
                    .font(.ui(15, weight: .bold)).foregroundStyle(Palette.goInk)
                if done.filled > 0 {
                    Text("Filled in blanks on \(ZohoImporter.count(done.filled, "customer")) you already had.").font(.ui(13)).foregroundStyle(Palette.secondary)
                }
                ForEach(done.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle").font(.ui(12.5)).foregroundStyle(Palette.watchInk)
                }
                Text("Everything is saved to your PavingData folder and kept in History. ⌘Z undoes the whole import.")
                    .font(.ui(12.5)).foregroundStyle(Palette.secondary)
            }
            HStack {
                if kept == nil {
                    Button("Undo import") { kept = ZohoImporter.undo(done, store: store, undoManager: undoManager) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Show customers") {
                    store.selection = .customers
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func line(_ icon: String, _ text: String, tone: Color = Palette.ink) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Palette.secondary)
            Text(text).font(.ui(13.5)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Palette.tertiary)
            Text(title).font(.ui(13, weight: .semibold)).lineLimit(1)
            Text(detail).font(.ui(12.5)).foregroundStyle(Palette.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func icon(_ kind: ZohoImport.Kind) -> String {
        switch kind {
        case .accounts: "building.2"
        case .contacts: "person.2"
        case .leads: "person.crop.circle.badge.questionmark"
        case .deals: "rectangle.split.3x1"
        case .notes: "note.text"
        case .unknown: "questionmark.square.dashed"
        }
    }
}
