import SwiftUI

/// Every saved version of every file, kept on this Mac. Pick a file, pick a version, put it back.
struct HistorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: HistoryRequest

    @State private var items: [AppStore.HistoryItem] = []
    @State private var selected: String?
    @State private var versions: [(version: Journal.Version, summary: String, changes: String)] = []
    @State private var query = ""
    @State private var confirm: Journal.Version?
    @State private var confirmJob: String?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History").font(.display(30))
                    Text("Every save is kept on this Mac, outside iCloud: all of them for two weeks, one an hour back to 90 days, then one a day for two years.")
                        .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Hairline()
            HStack(spacing: 0) {
                fileList.frame(width: 320)
                VRule()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 980, height: 640)
        .background(Palette.ground)
        .onAppear(perform: reload)
        .alert("Restore this version?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { version in
            Button("Restore") { restore(version) }
            Button("Cancel", role: .cancel) {}
        } message: { version in
            Text("\(version.label) goes back to how it was \(AppStore.when(version.savedAt)). What's there now stays in History.")
        }
        .alert("Bring this job back?", isPresented: Binding(get: { confirmJob != nil }, set: { if !$0 { confirmJob = nil } }), presenting: confirmJob) { folder in
            Button("Restore Job") { restoreJob(folder) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its details, measurements, estimate, logs and invoice come back as they were last saved. Photos and PDFs aren't kept in History; if the folder is in the Trash you can put those back from there.")
        }
        .alert("Couldn't restore", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: - File list

    private var groups: [(key: String, name: String, folder: String?, gone: Bool, items: [AppStore.HistoryItem])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.group.localizedCaseInsensitiveContains(q) }
        var result: [(String, String, String?, Bool, [AppStore.HistoryItem])] = []
        for name in ["Company", "Customers"] {
            let members = shown.filter { $0.group == name }.sorted { $0.title < $1.title }
            if !members.isEmpty { result.append((name, name, nil, false, members)) }
        }
        let jobItems = shown.filter { $0.file?.jobFolder != nil }
        let byFolder = Dictionary(grouping: jobItems) { $0.file?.jobFolder ?? "" }
        let ordered = byFolder.sorted { ($0.value.map(\.lastSaved).max() ?? .distantPast) > ($1.value.map(\.lastSaved).max() ?? .distantPast) }
        for (folder, members) in ordered {
            let order = JobPart.allCases.map(\.fileName)
            let sorted = members.sorted { (order.firstIndex(of: ($0.path as NSString).lastPathComponent) ?? 9) < (order.firstIndex(of: ($1.path as NSString).lastPathComponent) ?? 9) }
            let gone = store.jobID(inFolder: folder) == nil
            result.append(("job:" + folder, members.first?.group ?? folder, folder, gone, sorted))
        }
        return result
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary)
                TextField("Search jobs and files", text: $query).textFieldStyle(.plain).font(.ui(13))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.control))
            .padding(14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if items.isEmpty {
                            Text("Nothing saved yet.").font(.ui(13)).foregroundStyle(Palette.secondary).padding(12)
                        }
                        ForEach(groups, id: \.key) { group in
                            HStack(spacing: 6) {
                                Text(group.name.uppercased()).font(.eyebrow).tracking(0.7).foregroundStyle(Palette.tertiary).lineLimit(1)
                                if group.gone { Pill(text: "Gone", tone: .noGo) }
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                            ForEach(group.items) { item in
                                row(item, inJob: group.folder != nil).id(item.path)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            }
        }
        .background(Palette.surfaceSunk)
    }

    private func row(_ item: AppStore.HistoryItem, inJob: Bool) -> some View {
        let active = item.path == selected
        let name = inJob ? (item.file.map { file -> String in
            if case .job(_, let part) = file { return part.label }
            return item.title
        } ?? item.title) : item.title
        return Button {
            select(item.path)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.ui(13, weight: active ? .bold : .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text("\(item.versions) \(item.versions == 1 ? "version" : "versions") · \(AppStore.when(item.lastSaved))")
                        .font(.ui(11.5)).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if item.isGone && inJob == false { Pill(text: "Gone", tone: .noGo) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(active ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Palette.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Versions

    @ViewBuilder
    private var detail: some View {
        if let path = selected, let item = items.first(where: { $0.path == path }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.ui(18, weight: .bold))
                        Text("PavingData/\(item.path)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.tertiary).textSelection(.enabled)
                    }
                    Spacer()
                    if let folder = item.file?.jobFolder, store.jobID(inFolder: folder) == nil {
                        Button("Restore Job…") { confirmJob = folder }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(versions.enumerated()), id: \.element.version.id) { index, entry in
                            versionRow(entry.version, summary: entry.summary, changes: entry.changes, isCurrent: isCurrent(entry.version, index: index))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        } else {
            EmptyState(icon: "clock.arrow.circlepath", title: "Pick a file", message: "Choose a job or file on the left to see every version saved on this Mac.")
                .frame(maxHeight: .infinity)
        }
    }

    private func isCurrent(_ version: Journal.Version, index: Int) -> Bool {
        guard let record = store.records[version.path] else { return false }
        return record.sha == version.sha && versions.firstIndex(where: { $0.version.sha == version.sha }) == index
    }

    private func versionRow(_ version: Journal.Version, summary: String, changes: String, isCurrent: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(version.savedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.ui(13, weight: .semibold))
                    Pill(text: version.reason.label, tone: tone(version.reason))
                    if isCurrent { Pill(text: "Current", tone: .go, icon: "checkmark") }
                }
                Text(summary).font(.ui(12.5)).foregroundStyle(Palette.secondary).lineLimit(2)
                if !changes.isEmpty {
                    Text(changes).font(.ui(12)).foregroundStyle(Palette.tertiary).lineLimit(2)
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(version.size), countStyle: .file))
                .font(.ui(11.5)).foregroundStyle(Palette.tertiary).monospacedDigit()
            Button("Restore…") { confirm = version }
                .buttonStyle(SmallButtonStyle())
                .disabled(isCurrent || summary == "Can't be read")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    }

    private func tone(_ reason: Journal.Reason) -> Tone {
        switch reason {
        case .saved, .loaded: .neutral
        case .external: .info
        case .restored: .go
        case .unsaved, .conflictMine: .watch
        case .deleted, .setAside, .discarded: .noGo
        }
    }

    // MARK: - Actions

    private func reload() {
        items = store.historyItems()
        if selected == nil {
            selected = request.path.flatMap { p in items.contains { $0.path == p } ? p : nil }
                ?? request.jobFolder.flatMap { folder in items.first { $0.path == "jobs/\(folder)/job.json" }?.path }
        }
        if let selected { select(selected) }
    }

    private func select(_ path: String) {
        selected = path
        let file = DataFile(path: path)
        let list = Array(store.versions(of: path).prefix(300))
        let datas = list.map { store.versionData($0) }
        versions = list.indices.map { i in
            let summary = datas[i].map { VersionSummary.describe(file, $0) } ?? "Can't be read"
            var changes = ""
            if i + 1 < list.count {
                let found = VersionSummary.changes(from: datas[i + 1], to: datas[i])
                changes = found.prefix(2).map { "\($0.field): \($0.before) → \($0.after)" }.joined(separator: "   ")
                if found.count > 2 { changes += "   +\(found.count - 2) more" }
                if found.isEmpty, list[i].sha == list[i + 1].sha { changes = "Same as the version below" }
            } else {
                changes = "The oldest version kept"
            }
            return (list[i], summary, changes)
        }
    }

    private func restore(_ version: Journal.Version) {
        do {
            try store.restore(version)
        } catch {
            errorText = error.localizedDescription
        }
        reload()
    }

    private func restoreJob(_ folder: String) {
        do {
            try store.restoreJob(folder: folder)
        } catch {
            errorText = error.localizedDescription
        }
        reload()
    }
}
