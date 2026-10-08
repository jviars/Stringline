import SwiftUI
import AppKit

// MARK: - When the data folder can't be opened

/// Shown instead of setup when the remembered PavingData folder can't be opened yet,
/// so an offline or still-syncing folder is never mistaken for a fresh start.
struct DataProblemView: View {
    @Environment(AppStore.self) private var store
    let problem: LaunchProblem
    @State private var confirmStartOver = false
    @State private var confirmDefaults = false

    var body: some View {
        ZStack {
            Palette.asphalt.ignoresSafeArea()
            AggregateTexture().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    IconTile(systemName: icon, tone: tone, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOUR DATA IS SAFE").font(.eyebrow).tracking(0.9).foregroundStyle(Palette.goInk)
                        Text(title).font(.display(30)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(message)
                    .font(.ui(14))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                Text(problem.folder.path(percentEncoded: false))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 16)
                if problem.retriesOnItsOwn {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking again every few seconds. Stringline opens by itself when it's ready.")
                            .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                    }
                    .padding(.top, 14)
                }
                HStack(spacing: 10) {
                    Button("Try Again") { store.openFolder(problem.folder) }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .keyboardShortcut(.defaultAction)
                    Button("Locate Folder…") { locate() }
                        .buttonStyle(SecondaryButtonStyle(large: true))
                    if canUseDefaults {
                        Button("Use Default Settings…") { confirmDefaults = true }
                            .buttonStyle(SecondaryButtonStyle(large: true))
                    }
                }
                .padding(.top, 22)
                Hairline().padding(.top, 22)
                Button("Set up a new PavingData folder instead…") { confirmStartOver = true }
                    .buttonStyle(LinkButtonStyle())
                    .padding(.top, 14)
            }
            .padding(32)
            .frame(width: 640)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
        .confirmationDialog("Set up a new folder?", isPresented: $confirmStartOver) {
            Button("Set Up a New Folder") { store.forgetFolder() }
        } message: {
            Text("Nothing in the old folder is deleted. You can open it again later from Settings › Data & backups.")
        }
        .confirmationDialog("Start with default settings?", isPresented: $confirmDefaults) {
            Button("Use Default Settings") { store.rebuildSettings(in: problem.folder) }
        } message: {
            Text("Your jobs, customers and rates stay as they are. Only company details, crews and proposal wording go back to the defaults. The old settings file is set aside on this Mac.")
        }
    }

    private var canUseDefaults: Bool {
        switch problem {
        case .settingsDamaged: true
        case .settingsMissing(let url): FileManager.default.fileExists(atPath: url.appending(path: "jobs").path)
        default: false
        }
    }

    private var icon: String {
        switch problem {
        case .folderMissing: "questionmark.folder"
        case .settingsMissing, .settingsDownloading: "icloud.and.arrow.down"
        case .syncNotResponding: "icloud.slash"
        case .settingsDamaged: "exclamationmark.triangle"
        case .settingsUnreadable: "lock"
        case .settingsNewer: "arrow.up.circle"
        }
    }

    private var tone: Tone {
        switch problem {
        case .settingsDamaged, .settingsUnreadable: .noGo
        case .settingsNewer: .info
        default: .watch
        }
    }

    private var title: String {
        switch problem {
        case .folderMissing: "Can't find your PavingData folder"
        case .settingsMissing: "Waiting for your PavingData folder"
        case .settingsDownloading: "Waiting for iCloud"
        case .syncNotResponding: problem.folder.path.contains("Mobile Documents") ? "iCloud Drive isn't responding" : "The folder's sync service isn't responding"
        case .settingsDamaged: "Your settings file can't be read"
        case .settingsUnreadable: "Stringline can't read your settings"
        case .settingsNewer: "Update Stringline on this Mac"
        }
    }

    private var message: String {
        let iCloud = problem.folder.path.contains("Mobile Documents")
        switch problem {
        case .folderMissing:
            return iCloud
                ? "The folder isn't on this Mac right now. Check that this Mac is signed in to iCloud with iCloud Drive turned on. If you just set up this Mac, iCloud may still be bringing your files down."
                : "The folder isn't where it used to be. If it's on an external drive, plug the drive in. If you moved the folder, choose Locate Folder."
        case .settingsMissing:
            return "The folder is there, but its settings file isn't yet. If it's in iCloud Drive, it's probably still syncing. Nothing has been changed."
        case .settingsDownloading:
            return "Your settings file is in iCloud but hasn't downloaded to this Mac yet. Stringline asked iCloud for it and will open as soon as it arrives. Nothing has been changed."
        case .settingsDamaged:
            return "settings.json is damaged and there's no earlier copy of it on this Mac. Your jobs and customers are separate files and aren't affected. You can start with default settings, or pick a good copy from the backups folder."
        case .settingsUnreadable(_, let why):
            return "macOS wouldn't let Stringline read settings.json (\(why)). Check the folder's permissions in Finder › Get Info, then try again."
        case .settingsNewer:
            return "This folder was saved by a newer version of Stringline on another Mac. Update Stringline here so nothing gets lost. Nothing has been changed."
        case .syncNotResponding:
            return iCloud
                ? "macOS's iCloud Drive service on this Mac isn't answering, so Stringline can't read your folder yet. Nothing has been changed. If this lasts more than a few minutes, restart the Mac: that almost always clears it up."
                : "The app that syncs this folder isn't answering, so Stringline can't read it yet. Nothing has been changed. Try quitting and reopening that app, or restarting the Mac."
        }
    }

    private func locate() {
        guard let url = FilePicker.chooseFolder(title: "Find your PavingData folder", prompt: "Open", canCreate: false) else { return }
        store.openFolder(url)
    }
}

// MARK: - Two versions of a file

struct ConflictSheet: View {
    @Environment(AppStore.self) private var store
    let conflict: DataConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "arrow.triangle.branch", tone: .watch, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Two versions of \(conflict.title)").font(.display(26)).fixedSize(horizontal: false, vertical: true)
                    Text(explanation).font(.ui(13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                side(title: mineTitle, when: "Changed \(AppStore.when(conflict.mineDate))", data: conflict.mine, keepMine: true)
                side(title: theirsTitle, when: conflict.theirsDate.map { "Saved \(AppStore.when($0))" } ?? "Removed from the folder",
                     data: conflict.theirs, keepMine: false)
            }
            .padding(.top, 20)
            Label("Whichever you keep, the other version stays in History on this Mac, so you can switch back later.", systemImage: "clock.arrow.circlepath")
                .font(.ui(12.5))
                .foregroundStyle(Palette.secondary)
                .padding(.top, 18)
            if store.conflicts.count > 1 {
                Text("\(store.conflicts.count - 1) more to choose after this one.")
                    .font(.ui(12.5, weight: .semibold)).foregroundStyle(Palette.tertiary).padding(.top, 6)
            }
        }
        .padding(28)
        .frame(width: 660)
        .interactiveDismissDisabled()
    }

    private var isCopy: Bool {
        if case .iCloudCopy = conflict.source { return true }
        return false
    }

    private var explanation: String {
        isCopy
            ? "iCloud found two different copies of this file, usually because it was changed on two Macs before they synced. Pick the one to keep."
            : "It was changed in the PavingData folder, probably on another Mac, while this Mac had changes that weren't saved yet. Pick the one to keep."
    }

    private var mineTitle: String { isCopy ? "In the folder" : "This Mac" }
    private var theirsTitle: String { isCopy ? "iCloud's other copy" : "The folder (another Mac)" }

    /// What differs between the two, field by field (before = the other version, after = this Mac's).
    private var differences: [VersionSummary.Change] {
        Array(VersionSummary.changes(from: conflict.theirs, to: conflict.mine).prefix(6))
    }

    private func side(title: String, when: String, data: Data?, keepMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.eyebrow).tracking(0.8).foregroundStyle(Palette.tertiary)
            Text(data.map { VersionSummary.describe(DataFile(path: conflict.path), $0) } ?? "Deleted")
                .font(.ui(15, weight: .bold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(when).font(.ui(12.5)).foregroundStyle(Palette.secondary)
            if data != nil, !differences.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("WHAT'S DIFFERENT").font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(Palette.tertiary)
                    ForEach(differences, id: \.self) { change in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(change.field).font(.ui(11.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                            Text(keepMine ? change.after : change.before)
                                .font(.ui(12.5)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(keepMine ? Palette.accentWash : Palette.infoBg.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 6)
            Button(data == nil ? "Keep It Deleted" : "Keep This Version") {
                store.resolve(conflict, keepMine: keepMine)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .card(padding: 16, radius: 12)
    }
}

// MARK: - Another Mac has the folder open

struct LockPromptSheet: View {
    @Environment(AppStore.self) private var store
    let other: LockInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "desktopcomputer", tone: .info, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stringline is open on \(other.machineName)").font(.display(26)).fixedSize(horizontal: false, vertical: true)
                    Text("It was active \(RelativeDateTimeFormatter().localizedString(for: other.heartbeat, relativeTo: .now)). To keep your files safe, only one Mac saves changes at a time.")
                        .font(.ui(13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("Use This Mac") { store.takeOver() }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                Button("Just Look") { store.showLockPrompt = false }
                    .buttonStyle(SecondaryButtonStyle(large: true))
            }
            .padding(.top, 22)
            Text("Use This Mac stops \(other.machineName) from saving, and anything it already saved shows up here first. Just Look lets you browse without saving.")
                .font(.ui(12.5)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        .padding(28)
        .frame(width: 560)
    }
}

// MARK: - Banners

/// The floating messages at the bottom of the window: saving paused, recent notices, save problems.
struct StatusBanners: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            if let toast = store.toast {
                banner(icon: "info.circle.fill", tint: Palette.infoInk, background: Palette.infoBg, text: toast) {
                    Button("OK") { store.toast = nil }.buttonStyle(SmallButtonStyle())
                }
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    if store.toast == toast { store.toast = nil }
                }
            }
            if let other = store.savingPaused {
                banner(icon: "pause.circle.fill", tint: Palette.watchInk, background: Palette.watchBg,
                       text: "Saving is paused: Stringline is open on \(other.machineName).\(store.pendingCount > 0 ? " \(store.pendingCount) \(store.pendingCount == 1 ? "change is" : "changes are") waiting." : "")") {
                    Button("Use This Mac") { store.takeOver() }.buttonStyle(SmallButtonStyle())
                }
            }
            if let problem = store.problem {
                banner(icon: "exclamationmark.triangle.fill", tint: Palette.noGoInk, background: Palette.noGoBg, text: problem) {
                    if problem.hasPrefix("Couldn't save") {
                        Button("Try Again") { store.flush() }.buttonStyle(SmallButtonStyle())
                    }
                    Button("Dismiss") { store.problem = nil }.buttonStyle(SmallButtonStyle())
                }
            }
        }
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.2), value: store.toast)
    }

    private func banner<Actions: View>(icon: String, tint: Color, background: Color, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.ui(12.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(3).frame(maxWidth: 560, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - A job file that can't be opened

struct FileUnavailableView: View {
    @Environment(AppStore.self) private var store
    let job: Job
    let part: JobPart
    let issue: FileIssue

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                IconTile(systemName: icon, tone: issue.waitsOnItsOwn ? .info : .noGo, size: 52)
                Text(title).font(.ui(17, weight: .bold)).foregroundStyle(Palette.ink).padding(.top, 4)
                Text(issue.explanation)
                    .font(.ui(13)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
                if issue.waitsOnItsOwn {
                    ProgressView().controlSize(.small).padding(.top, 4)
                }
                HStack(spacing: 8) {
                    Button("Check Again") { store.checkHealth() }.buttonStyle(SecondaryButtonStyle())
                    if !store.versions(of: path).isEmpty {
                        Button("Open History…") { store.historyRequest = HistoryRequest(jobFolder: job.folderName, path: path) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Show in Finder") {
                        if let url = store.jobFolder(job) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 620)
            .card()
            .padding(.top, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var path: String { "jobs/\(job.folderName)/\(part.fileName)" }

    private var icon: String {
        switch issue {
        case .downloading: "icloud.and.arrow.down"
        case .syncNotResponding: "icloud.slash"
        case .damaged: "exclamationmark.triangle"
        case .unreadable: "lock"
        case .newerVersion: "arrow.up.circle"
        }
    }

    private var title: String {
        let thing = "This job's \(part.label.lowercased())"
        let verb = part.isPlural ? "are" : "is"
        switch issue {
        case .downloading: return "\(thing) \(verb) still downloading"
        case .syncNotResponding: return "\(thing) \(verb) waiting for iCloud"
        case .damaged: return "\(thing) can't be read"
        case .unreadable: return "\(thing) can't be opened"
        case .newerVersion: return "\(thing) \(part.isPlural ? "were" : "was") saved by a newer Stringline"
        }
    }
}
