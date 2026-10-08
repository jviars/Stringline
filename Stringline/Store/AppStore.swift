import Foundation
import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case today, pipeline, measure, jobs, schedule, customers, invoices, equipment, crew, documents, learn, settings
    case job(UUID)
}

enum JobTab: String, CaseIterable, Identifiable {
    case overview, measure, estimate, schedule, logs, photos, invoice
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: "Overview"
        case .measure: "Measure"
        case .estimate: "Estimate"
        case .schedule: "Schedule"
        case .logs: "Daily logs"
        case .photos: "Photos"
        case .invoice: "Invoice"
        }
    }

    /// The file this tab edits, besides job.json.
    var part: JobPart? {
        switch self {
        case .measure: .takeoff
        case .estimate: .estimate
        case .logs: .logs
        case .invoice: .invoice
        case .overview, .schedule, .photos: nil
        }
    }
}

enum SaveKey: Hashable {
    case settings, rates
    case customer(UUID)
    case job(UUID), takeoff(UUID), estimate(UUID), logs(UUID), invoice(UUID)
}

/// What Stringline last saw of a file on disk, to tell its own saves from changes made elsewhere.
struct FileRecord: Equatable {
    var sha: String
    var stamp: FileStamp?
}

/// Opens the History browser, optionally at one job or file.
struct HistoryRequest: Identifiable, Equatable {
    let id = UUID()
    var jobFolder: String?
    var path: String?
}

/// Everything the app knows lives in memory here and is written back to plain files
/// in the PavingData folder shortly after each change.
///
/// Safety rules (see AppStore+Safety.swift):
/// - A file that couldn't be read is never written over.
/// - Before every save the file on disk is compared with what was last read or written;
///   if it changed somewhere else, the two versions go to the person to choose, never silently overwritten.
/// - Every version is recorded in a SQLite history on this Mac (outside iCloud).
/// - Only one Mac saves at a time.
@Observable @MainActor
final class AppStore {
    // MARK: Data
    var dataFolder: URL?
    var settings = AppSettings()
    var rates = Rates()
    var customers: [Customer] = []
    var jobs: [Job] = []
    var takeoffs: [UUID: Takeoff] = [:]
    var estimates: [UUID: Estimate] = [:]
    var logs: [UUID: JobLogs] = [:]
    var invoices: [UUID: Invoice] = [:]
    var lastSaved: Date?
    var problem: String?
    var notices: [String] = []
    var toast: String?

    // MARK: Safety state
    var launchProblem: LaunchProblem?
    /// Files that couldn't be read, by path. They're never written over.
    var unavailable: [String: FileIssue] = [:]
    var conflicts: [DataConflict] = []
    /// Set while another Mac is the one saving.
    var savingPaused: LockInfo?
    var showLockPrompt = false
    var health: HealthReport?
    /// iCloud copies of a whole job folder ("2026-001-plaza 2") → the folder they copy.
    var duplicateFolders: [String: String] = [:]
    var unsavedLastTime: [Journal.Version] = []
    var pendingCount = 0
    var historyRequest: HistoryRequest?
    /// Files picked for File › Import from Zoho…, waiting in the import window.
    var zohoImport: ZohoImport.Session?
    var settingsSectionRequest: SettingsSection?

    // MARK: UI state
    var selection: SidebarItem = .today
    var jobTab: JobTab = .overview
    var tourStop: TourStop?
    var showSearch = false
    var showNewLead = false
    var recentJobIDs: [UUID] = []
    /// What the assistant is pointing at or just changed (estimate lines, schedule days, jobs).
    var assistantHighlights: Set<UUID> = []
    /// Shapes the assistant has drawn that are waiting for Apply, by job: Measure shows them dashed.
    var assistantPreview: [UUID: [TakeoffShape]] = [:]
    /// A place on screen the assistant is pointing at (a KnowledgeBase spot id).
    var assistantSpotlight: String?
    /// What's on screen, so the assistant knows where the person is.
    var visibleScheduleWeek: Date?
    var visibleCustomerID: UUID?
    /// Requests from the assistant to show a week or a customer.
    var scheduleWeekRequest: Date?
    var customerRequest: UUID?

    let weather = WeatherModel()
    var logoImage: NSImage?

    @ObservationIgnored var pending: Set<SaveKey> = [] { didSet { if pendingCount != pending.count { pendingCount = pending.count } } }
    @ObservationIgnored var records: [String: FileRecord] = [:]
    @ObservationIgnored var extras: [String: JSONFile.Extras] = [:]
    @ObservationIgnored var journal: Journal?
    @ObservationIgnored var watcher: FolderWatcher?
    @ObservationIgnored var lock: FolderLock?
    @ObservationIgnored var syncObserver: NSObjectProtocol?
    @ObservationIgnored var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored var rescanTask: Task<Void, Never>?
    @ObservationIgnored var retryTask: Task<Void, Never>?
    @ObservationIgnored var launchRetryTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLogo: Data?

    /// Lets the debug self-test drive onboarding steps.
    var onboardingStepRequest: Int?
    /// False for the self-test, so it never touches the real app's preferences.
    @ObservationIgnored let persistsPreferences: Bool
    /// ~/Library/Application Support/Stringline: history, local backups and set-aside files. Never synced.
    @ObservationIgnored let localRoot: URL
    @ObservationIgnored let machineID: String
    @ObservationIgnored let machineName: String

    init(isolated: Bool = false, localRoot: URL? = nil, machineID: String? = nil, machineName: String? = nil) {
        persistsPreferences = !isolated
        self.localRoot = localRoot ?? Self.defaultLocalRoot
        self.machineID = machineID ?? Self.thisMachineID()
        self.machineName = machineName ?? FolderLock.computerName
        guard !isolated else { return }
        recentJobIDs = (UserDefaults.standard.stringArray(forKey: "recentJobs") ?? []).compactMap(UUID.init(uuidString:))
        if let path = UserDefaults.standard.string(forKey: "dataFolderPath") {
            openFolder(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    var needsOnboarding: Bool { launchProblem == nil && (dataFolder == nil || !settings.onboardingComplete) }

    static var defaultLocalRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Stringline", directoryHint: .isDirectory)
    }

    private static func thisMachineID() -> String {
        if let id = UserDefaults.standard.string(forKey: "machineID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "machineID")
        return id
    }

    // MARK: - Folder locations

    #if DEBUG
    /// The self-test's stand-in for iCloud Drive, so it never touches the real one.
    static var testICloudDrive: URL?
    #endif

    static var iCloudDrive: URL? {
        #if DEBUG
        if let testICloudDrive { return testICloudDrive }
        #endif
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var suggestedICloudFolder: URL? {
        iCloudDrive?.appending(path: "Stringline/PavingData", directoryHint: .isDirectory)
    }

    var isInICloud: Bool {
        dataFolder?.path.contains("Mobile Documents/com~apple~CloudDocs") ?? false
    }

    func jobFolder(_ job: Job) -> URL? {
        guard let root = dataFolder, !job.folderName.isEmpty else { return nil }
        return root.appending(path: "jobs/\(job.folderName)", directoryHint: .isDirectory)
    }

    func photosFolder(_ job: Job) -> URL? { jobFolder(job)?.appending(path: "photos", directoryHint: .isDirectory) }
    func docsFolder(_ job: Job) -> URL? { jobFolder(job)?.appending(path: "docs", directoryHint: .isDirectory) }
    var logoURL: URL? { dataFolder?.appending(path: "logo.png") }

    /// One history database per PavingData folder, named from the folder's path.
    func historyURL(for folder: URL) -> URL {
        let id = SafeFile.sha256(Data(folder.standardizedFileURL.path.utf8)).prefix(16)
        return localRoot.appending(path: "History/\(id).sqlite")
    }

    func localBackupsFolder(for folder: URL) -> URL {
        let id = SafeFile.sha256(Data(folder.standardizedFileURL.path.utf8)).prefix(16)
        return localRoot.appending(path: "Backups/\(id)", directoryHint: .isDirectory)
    }

    var setAsideFolder: URL { localRoot.appending(path: "Set Aside", directoryHint: .isDirectory) }

    // MARK: - Create / open the data folder

    enum FolderError: LocalizedError {
        case notAStringlineFolder
        case couldNotOpen(String)
        var errorDescription: String? {
            switch self {
            case .notAStringlineFolder: "That folder doesn't have a settings.json file, so it isn't a PavingData folder."
            case .couldNotOpen(let why): why
            }
        }
    }

    func createDataFolder(at url: URL) throws {
        // Never start fresh on top of an existing folder, even one iCloud hasn't finished downloading.
        if SafeFile.exists(url.appending(path: "settings.json")) {
            try openExistingFolder(url)
            return
        }
        let fm = FileManager.default
        for sub in ["customers", "jobs", "backups"] {
            try fm.createDirectory(at: url.appending(path: sub, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        try JSONFile.write(settings, to: url.appending(path: "settings.json"))
        try JSONFile.write(rates, to: url.appending(path: "rates.json"))
        openFolder(url)
        if dataFolder == nil { throw FolderError.couldNotOpen("The new folder couldn't be opened.") }
        flush()
    }

    func openExistingFolder(_ url: URL) throws {
        guard SafeFile.exists(url.appending(path: "settings.json")) else { throw FolderError.notAStringlineFolder }
        openFolder(url)
    }

    /// Opens a PavingData folder. The settings file is checked first: a folder that's offline,
    /// still syncing or damaged shows a problem screen and is never treated as a fresh start.
    func openFolder(_ url: URL) {
        if dataFolder != nil { closeFolder() }
        launchRetryTask?.cancel()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            failToOpen(.folderMissing(url))
            return
        }
        let journal = Journal(url: historyURL(for: url), folderPath: url.standardizedFileURL.path)
        let unsaved = journal.latestVersions().filter { $0.reason == .unsaved }
        notices = []
        switch JSONFile.load(AppSettings.self, from: url.appending(path: "settings.json")) {
        case .ok: break
        case .missing: return failToOpen(.settingsMissing(url))
        case .notDownloaded: return failToOpen(.settingsDownloading(url))
        case .notResponding: return failToOpen(.syncNotResponding(url))
        case .unreadable(let why): return failToOpen(.settingsUnreadable(url, why))
        case .newer: return failToOpen(.settingsNewer(url))
        case .damaged(let bytes):
            guard restoreDamaged("settings.json", bytes: bytes, root: url, journal: journal, as: AppSettings.self, label: "Settings") != nil else {
                return failToOpen(.settingsDamaged(url))
            }
        }
        launchProblem = nil
        self.journal = journal
        dataFolder = url
        if persistsPreferences { UserDefaults.standard.set(url.path, forKey: "dataFolderPath") }
        load()
        unsavedLastTime = unsaved.filter { records[$0.path]?.sha != $0.sha }
        if !unsavedLastTime.isEmpty {
            let one = unsavedLastTime.count == 1
            notify("\(unsavedLastTime.count) \(one ? "change wasn't" : "changes weren't") saved last time. \(one ? "It's" : "They're") kept on this Mac: see Settings › Data & backups.")
        }
        if let problem = journal.problem { notify(problem) }
        startWatching()
        acquireLock()
        journal.thin()
    }

    private func failToOpen(_ problem: LaunchProblem) {
        launchProblem = problem
        dataFolder = nil
        guard problem.retriesOnItsOwn else { return }
        let url = problem.folder
        launchRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.launchProblem?.folder == url else { return }
            self.openFolder(url)
        }
    }

    /// Lets go of the current folder: saves what's waiting, stops watching and hands the lock back.
    func closeFolder(releaseLock: Bool = true) {
        flush()
        // Anything that still couldn't be written is kept in this folder's History, never carried to another folder.
        if !pending.isEmpty { keepUnsavedInHistory() }
        heartbeatTask?.cancel()
        rescanTask?.cancel()
        retryTask?.cancel()
        watcher?.stop()
        watcher = nil
        if releaseLock, savingPaused == nil { lock?.release() }
        lock = nil
        journal?.close()
        journal = nil
        dataFolder = nil
        savingPaused = nil
        showLockPrompt = false
    }

    /// From the problem screen: stop looking for the old folder and set up a new one. Nothing is deleted.
    func forgetFolder() {
        launchRetryTask?.cancel()
        if persistsPreferences { UserDefaults.standard.removeObject(forKey: "dataFolderPath") }
        launchProblem = nil
        dataFolder = nil
        settings = AppSettings()
        rates = Rates()
    }

    // MARK: - Load

    func load() {
        guard let root = dataFolder else { return }
        unavailable = [:]; records = [:]; extras = [:]; conflicts = []; duplicateFolders = [:]
        settings = readFile(AppSettings.self, .settings) ?? settings
        rates = readFile(Rates.self, .rates) ?? Rates()
        logoImage = logoURL.flatMap { NSImage(contentsOf: $0) }

        let listing = DataFile.list(root)
        customers = listing.files.union(listing.placeholders).sorted()
            .compactMap { path -> Customer? in
                guard let file = DataFile(path: path), case .customer = file else { return nil }
                return readFile(Customer.self, file)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var loaded: [Job] = []
        takeoffs = [:]; estimates = [:]; logs = [:]; invoices = [:]
        for folder in listing.jobFolders {
            // iCloud sometimes duplicates a whole job folder ("2026-001-plaza 2"). Use the first; leave the copy alone.
            if case .ok(let peek, _, _) = JSONFile.load(Job.self, from: root.appending(path: "jobs/\(folder)/job.json")),
               let original = loaded.first(where: { $0.id == peek.id }) {
                duplicateFolders[folder] = original.folderName
                continue
            }
            guard var job = readFile(Job.self, .job(folder: folder, part: .job)) else { continue }
            job.folderName = folder
            loaded.append(job)
            takeoffs[job.id] = readFile(Takeoff.self, .job(folder: folder, part: .takeoff)) ?? Takeoff()
            estimates[job.id] = readFile(Estimate.self, .job(folder: folder, part: .estimate)) ?? Estimate()
            logs[job.id] = readFile(JobLogs.self, .job(folder: folder, part: .logs)) ?? JobLogs()
            invoices[job.id] = readFile(Invoice.self, .job(folder: folder, part: .invoice))
        }
        jobs = loaded.sorted { $0.created > $1.created }
        recentJobIDs = recentJobIDs.filter { id in jobs.contains { $0.id == id } }
        announceUnavailable()
        handleICloudCopies(listing)
        refreshWeather()
        runBackupIfDue()
    }

    /// Reads one file. Damaged files are restored from History when a good copy exists;
    /// anything else that can't be read is listed in `unavailable` and left alone.
    func readFile<T: Codable & DefaultInit>(_ type: T.Type, _ file: DataFile) -> T? {
        guard let root = dataFolder else { return nil }
        let rel = file.path
        switch JSONFile.load(T.self, from: root.appending(path: rel)) {
        case .missing:
            return nil
        case .notDownloaded:
            unavailable[rel] = .downloading
        case .notResponding:
            unavailable[rel] = .syncNotResponding
        case .unreadable(let why):
            unavailable[rel] = .unreadable(why)
        case .newer:
            unavailable[rel] = .newerVersion
        case .damaged(let bytes):
            if let value = restoreDamaged(rel, bytes: bytes, root: root, journal: journal, as: T.self, label: label(for: file)) { return value }
            unavailable[rel] = .damaged
        case .ok(let value, let data, let extra):
            remember(rel, data, extras: extra, reason: .loaded, label: label(for: file, value: value))
            return value
        }
        return nil
    }

    // MARK: - Saving

    func markDirty(_ key: SaveKey) {
        if let file = file(for: key), let issue = unavailable[file.path] {
            problem = "\(label(for: file)) can't be changed right now: it's \(issue.short)."
            return
        }
        pending.insert(key)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    static let backupWaitingPrefix = "Backup is waiting:"
    static let syncStuckProblem = "iCloud Drive isn't responding on this Mac. Your changes are kept here and save by themselves when it's back. If it lasts, restarting the Mac usually fixes it."

    enum SaveError: LocalizedError {
        case waitingForDownload
        case cantCheck(String)
        var errorDescription: String? {
            switch self {
            case .waitingForDownload: "Waiting for iCloud to download the latest copy first."
            case .cantCheck(let why): "The saved copy couldn't be checked (\(why))."
            }
        }
    }

    func flush() {
        guard let root = dataFolder, !pending.isEmpty, savingPaused == nil else { return }
        if let other = lock?.otherOwner() {
            pause(for: other)
            return
        }
        let keys = pending
        pending.removeAll()
        var failure: String?
        var waiting = false
        var syncStuck = false
        for key in keys {
            do {
                try write(key, root: root)
            } catch SaveError.waitingForDownload {
                pending.insert(key)
                waiting = true
            } catch SafeFile.Failure.notResponding {
                pending.insert(key)
                syncStuck = true
            } catch {
                pending.insert(key)
                failure = error.localizedDescription
            }
        }
        if let failure {
            problem = "Couldn't save: \(failure) Stringline will keep trying."
        } else if syncStuck {
            problem = Self.syncStuckProblem
        } else {
            if problem?.hasPrefix("Couldn't save") == true || problem == Self.syncStuckProblem { problem = nil }
            lastSaved = .now
        }
        if failure != nil || waiting || syncStuck { scheduleRetry() }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves one file, but only if the copy on disk is still the one last read or written here.
    private func write(_ key: SaveKey, root: URL) throws {
        guard let file = file(for: key) else { return }
        let rel = file.path
        guard unavailable[rel] == nil, !conflicts.contains(where: { $0.path == rel }) else { return }
        if let folder = file.jobFolder, duplicateFolders[folder] != nil { return }
        let url = root.appending(path: rel)
        let label = label(for: file)
        let data = try encodedValue(for: key, path: rel)

        let disk = SafeFile.read(url)
        switch disk {
        case .notDownloaded:
            throw SaveError.waitingForDownload
        case .notResponding:
            if let data { journal?.record(rel, data, reason: .unsaved, label: label) }
            throw SafeFile.Failure.notResponding
        case .unreadable(let why):
            if let data { journal?.record(rel, data, reason: .unsaved, label: label) }
            throw SaveError.cantCheck(why)
        case .missing:
            if records[rel] != nil, data != nil {
                raiseConflict(file, mine: data, theirs: nil, theirsDate: nil, source: .changedElsewhere)
                return
            }
        case .bytes(let current):
            if let data, current == data {
                records[rel] = FileRecord(sha: SafeFile.sha256(current), stamp: SafeFile.stamp(url))
                return
            }
            if SafeFile.sha256(current) != records[rel]?.sha {
                raiseConflict(file, mine: data, theirs: current, theirsDate: SafeFile.modified(url), source: .changedElsewhere)
                return
            }
        }

        if let data {
            let entry = journal?.record(rel, data, reason: .unsaved, label: label)
            try SafeFile.write(data, to: url)
            records[rel] = FileRecord(sha: SafeFile.sha256(data), stamp: SafeFile.stamp(url))
            if let entry { journal?.mark(entry, as: .saved) }
        } else if case .bytes(let current) = disk {
            journal?.record(rel, current, reason: .deleted, label: label)
            if case .customer = file {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } else {
                try SafeFile.remove(url)
            }
            records[rel] = nil
            extras[rel] = nil
        }
    }

    /// The bytes a key should have on disk now, or nil if its file should be removed.
    func encodedValue(for key: SaveKey, path: String) throws -> Data? {
        let extra = extras[path]
        let name = (path as NSString).lastPathComponent
        switch key {
        case .settings: return try JSONFile.encode(settings, preserving: extra, name: name)
        case .rates: return try JSONFile.encode(rates, preserving: extra, name: name)
        case .customer(let id): return try customers.first { $0.id == id }.map { try JSONFile.encode($0, preserving: extra, name: name) }
        case .job(let id): return try job(id).map { try JSONFile.encode($0, preserving: extra, name: name) }
        case .takeoff(let id): return try JSONFile.encode(takeoffs[id] ?? Takeoff(), preserving: extra, name: name)
        case .estimate(let id): return try JSONFile.encode(estimates[id] ?? Estimate(), preserving: extra, name: name)
        case .logs(let id): return try JSONFile.encode(logs[id] ?? JobLogs(), preserving: extra, name: name)
        case .invoice(let id): return try invoices[id].map { try JSONFile.encode($0, preserving: extra, name: name) }
        }
    }

    // MARK: - Logo

    /// Saves the logo as logo.png in the data folder (or holds it until the folder exists).
    @discardableResult
    func setLogo(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        logoImage = image
        settings.company.hasLogo = true
        markDirty(.settings)
        if let target = logoURL {
            do { try SafeFile.write(png, to: target) } catch { problem = "Couldn't save the logo: \(error.localizedDescription)" }
        } else {
            pendingLogo = png
        }
        return true
    }

    func savePendingLogo() {
        guard let data = pendingLogo, let target = logoURL else { return }
        try? SafeFile.write(data, to: target)
        pendingLogo = nil
    }

    // MARK: - Lookups

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }
    func customer(_ id: UUID?) -> Customer? { id.flatMap { cid in customers.first { $0.id == cid } } }
    func customerName(for job: Job) -> String { customer(job.customerID)?.name ?? "No customer" }
    func crew(_ id: UUID?) -> Crew? { id.flatMap { cid in settings.crews.first { $0.id == cid } } }
    func jobID(inFolder folder: String) -> UUID? { jobs.first { $0.folderName == folder }?.id }

    func priceCents(for jobID: UUID) -> Int? {
        guard let option = estimates[jobID]?.selected, !option.items.isEmpty else { return nil }
        return option.breakdown.priceCents
    }

    func summary(for jobID: UUID) -> TakeoffSummary {
        Estimator.summary(takeoffs[jobID] ?? Takeoff(), factors: rates.factors)
    }

    var realJobs: [Job] { jobs.filter { !$0.isSample } }

    func file(for key: SaveKey) -> DataFile? {
        func part(_ id: UUID, _ part: JobPart) -> DataFile? {
            guard let job = job(id), !job.folderName.isEmpty else { return nil }
            return .job(folder: job.folderName, part: part)
        }
        switch key {
        case .settings: return .settings
        case .rates: return .rates
        case .customer(let id): return .customer(id)
        case .job(let id): return part(id, .job)
        case .takeoff(let id): return part(id, .takeoff)
        case .estimate(let id): return part(id, .estimate)
        case .logs(let id): return part(id, .logs)
        case .invoice(let id): return part(id, .invoice)
        }
    }

    func key(for file: DataFile) -> SaveKey? {
        switch file {
        case .settings: return .settings
        case .rates: return .rates
        case .customer(let id): return .customer(id)
        case .job(let folder, let part):
            guard let id = jobID(inFolder: folder) else { return nil }
            switch part {
            case .job: return .job(id)
            case .takeoff: return .takeoff(id)
            case .estimate: return .estimate(id)
            case .logs: return .logs(id)
            case .invoice: return .invoice(id)
            }
        }
    }

    /// A name people recognize, like "Maple Ridge Plaza · Estimate".
    func label(for file: DataFile, value: Any? = nil) -> String {
        switch file {
        case .settings: return "Settings"
        case .rates: return "Rates & prices"
        case .customer(let id):
            let name = (value as? Customer)?.name ?? customers.first { $0.id == id }?.name ?? ""
            return name.isEmpty ? "A customer" : name
        case .job(let folder, let part):
            let name = (value as? Job)?.name ?? jobs.first { $0.folderName == folder }?.name ?? folder
            return "\(name) · \(part.label)"
        }
    }

    /// The parts of a job that can't be opened right now, and why.
    func unavailableParts(of jobID: UUID) -> [JobPart: FileIssue] {
        guard let job = job(jobID) else { return [:] }
        var result: [JobPart: FileIssue] = [:]
        for part in JobPart.allCases {
            if let issue = unavailable["jobs/\(job.folderName)/\(part.fileName)"] { result[part] = issue }
        }
        return result
    }

    // MARK: - Bindings that save on change

    var settingsBinding: Binding<AppSettings> {
        Binding(get: { self.settings }, set: { self.settings = $0; self.markDirty(.settings) })
    }

    var ratesBinding: Binding<Rates> {
        Binding(get: { self.rates }, set: { self.rates = $0; self.markDirty(.rates) })
    }

    func jobBinding(_ id: UUID) -> Binding<Job> {
        Binding(
            get: { self.job(id) ?? Job() },
            set: { new in
                guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                var updated = new
                updated.updated = .now
                if updated.stage != self.jobs[i].stage { updated.stageChanged = .now }
                self.jobs[i] = updated
                self.markDirty(.job(id))
            })
    }

    func customerBinding(_ id: UUID) -> Binding<Customer> {
        Binding(
            get: { self.customers.first { $0.id == id } ?? Customer() },
            set: { new in
                guard let i = self.customers.firstIndex(where: { $0.id == id }) else { return }
                self.customers[i] = new
                self.markDirty(.customer(id))
            })
    }

    func takeoffBinding(_ id: UUID) -> Binding<Takeoff> {
        Binding(get: { self.takeoffs[id] ?? Takeoff() }, set: { self.takeoffs[id] = $0; self.markDirty(.takeoff(id)) })
    }

    func estimateBinding(_ id: UUID) -> Binding<Estimate> {
        Binding(get: { self.estimates[id] ?? Estimate() }, set: { self.estimates[id] = $0; self.markDirty(.estimate(id)) })
    }

    func logsBinding(_ id: UUID) -> Binding<JobLogs> {
        Binding(get: { self.logs[id] ?? JobLogs() }, set: { self.logs[id] = $0; self.markDirty(.logs(id)) })
    }

    func invoiceBinding(_ id: UUID) -> Binding<Invoice?> {
        Binding(get: { self.invoices[id] }, set: { self.invoices[id] = $0; self.markDirty(.invoice(id)) })
    }

    // MARK: - Mutations

    @discardableResult
    func createCustomer(name: String, type: CustomerType = .commercial) -> Customer {
        var customer = Customer()
        customer.name = name
        customer.type = type
        customers.append(customer)
        customers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        markDirty(.customer(customer.id))
        return customer
    }

    func deleteCustomer(_ id: UUID) {
        customers.removeAll { $0.id == id }
        for i in jobs.indices where jobs[i].customerID == id {
            jobs[i].customerID = nil
            markDirty(.job(jobs[i].id))
        }
        markDirty(.customer(id))
    }

    @discardableResult
    func createJob(name: String, customerID: UUID? = nil, address: String = "", type: CustomerType = .commercial,
                   services: [Service] = [], stage: Stage = .lead, source: String = "",
                   coordinate: Coordinate? = nil, isSample: Bool = false, id: UUID? = nil) -> Job {
        var job = Job()
        if let id { job.id = id }
        job.name = name.isEmpty ? "Untitled job" : name
        job.customerID = customerID
        job.address = address
        job.type = type
        job.services = services
        job.stage = stage
        job.source = source
        job.latitude = coordinate?.lat
        job.longitude = coordinate?.lon
        job.isSample = isSample
        if isSample {
            job.number = "SAMPLE"
            job.folderName = "sample-practice-plaza"
        } else {
            let year = Calendar.current.component(.year, from: .now)
            let prefix = "\(year)-"
            let next = (jobs.filter { $0.number.hasPrefix(prefix) }
                .compactMap { Int($0.number.dropFirst(prefix.count)) }.max() ?? 0) + 1
            job.number = String(format: "%d-%03d", year, next)
            job.folderName = "\(job.number)-\(Fmt.slug(job.name))"
        }
        // Never reuse a folder that's already there (another Mac may have made one with the same number).
        if let root = dataFolder {
            let base = job.folderName
            var n = 2
            while FileManager.default.fileExists(atPath: root.appending(path: "jobs/\(job.folderName)").path)
                    || jobs.contains(where: { $0.folderName == job.folderName }) {
                job.folderName = "\(base)-\(n)"
                n += 1
            }
        }
        jobs.insert(job, at: 0)
        takeoffs[job.id] = Takeoff()
        estimates[job.id] = Estimate()
        logs[job.id] = JobLogs()
        if let dir = jobFolder(job) {
            try? FileManager.default.createDirectory(at: dir.appending(path: "photos", directoryHint: .isDirectory), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: dir.appending(path: "docs", directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        markDirty(.job(job.id)); markDirty(.takeoff(job.id)); markDirty(.estimate(job.id)); markDirty(.logs(job.id))
        return job
    }

    func deleteJob(_ id: UUID) {
        guard let job = job(id) else { return }
        if let root = dataFolder {
            for part in JobPart.allCases {
                let rel = "jobs/\(job.folderName)/\(part.fileName)"
                if case .bytes(let data) = SafeFile.read(root.appending(path: rel)) {
                    journal?.record(rel, data, reason: .deleted, label: "\(job.name) · \(part.label)")
                }
                records[rel] = nil
                unavailable[rel] = nil
                extras[rel] = nil
            }
        }
        if let dir = jobFolder(job), JSONFile.exists(dir) {
            try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        }
        for key in [SaveKey.job(id), .takeoff(id), .estimate(id), .logs(id), .invoice(id)] { pending.remove(key) }
        jobs.removeAll { $0.id == id }
        takeoffs[id] = nil; estimates[id] = nil; logs[id] = nil; invoices[id] = nil
        recentJobIDs.removeAll { $0 == id }
        if case .job(let open) = selection, open == id { selection = .jobs }
    }

    func setStage(_ id: UUID, _ stage: Stage) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].stage != stage else { return }
        jobs[i].stage = stage
        jobs[i].stageChanged = .now
        jobs[i].updated = .now
        if stage == .sent && jobs[i].sentOn == nil { jobs[i].sentOn = .now }
        markDirty(.job(id))
    }

    func openJob(_ id: UUID, tab: JobTab = .overview) {
        jobTab = tab
        selection = .job(id)
        recentJobIDs.removeAll { $0 == id }
        recentJobIDs.insert(id, at: 0)
        recentJobIDs = Array(recentJobIDs.prefix(6))
        if persistsPreferences { UserDefaults.standard.set(recentJobIDs.map(\.uuidString), forKey: "recentJobs") }
    }

    func nextProposalNumber() -> String {
        let year = Calendar.current.component(.year, from: .now)
        let number = String(format: "%d-%03d", year, settings.nextProposalNumber)
        settings.nextProposalNumber += 1
        markDirty(.settings)
        return number
    }

    func nextInvoiceNumber() -> String {
        let number = String(settings.nextInvoiceNumber)
        settings.nextInvoiceNumber += 1
        markDirty(.settings)
        return number
    }

    // MARK: - Practice job

    var practiceJob: Job? { jobs.first { $0.isSample } }

    @discardableResult
    func ensurePracticeJob() -> Job {
        if let existing = practiceJob { return existing }
        let center = settings.company.homeLatitude.flatMap { lat in
            settings.company.homeLongitude.map { Coordinate(lat: lat, lon: $0) }
        }
        var job = createJob(name: "Practice Plaza", address: "Sample job · fake numbers", type: .commercial,
                            services: [.millOverlay, .patching, .striping], stage: .estimating,
                            source: "Sample", coordinate: center, isSample: true)
        job.notes = "This is a practice job. Measure anything, build an estimate, even email yourself the proposal. Reset it from Learn Stringline."
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job }
        markDirty(.job(job.id))
        return job
    }

    /// Gives Practice Plaza a sample estimate (a typical mill & overlay) so the tour has something to show.
    func seedPracticeEstimate(_ id: UUID) {
        guard estimates[id]?.options.isEmpty ?? true else { return }
        var sample = TakeoffSummary()
        sample.areaSqFt[.millOverlay] = 44_850
        sample.areaSqFt[.fullDepthPatch] = 1_350
        sample.lineFt[.striping] = 2_860
        sample.counts[.stall] = 112
        sample.surfaceTons = 44_850 / 9 * 2 * rates.factors.mixLbPerSYInch / 2000
        sample.baseTons = 1_350 / 9 * 4 * rates.factors.mixLbPerSYInch / 2000
        var option = EstimateOption()
        option.title = "Mill & overlay"
        option.items = Estimator.buildItems(sample, takeoff: Takeoff(), rates: rates).map { var item = $0; item.key = ""; item.fromTakeoff = false; return item }
        option.overheadPct = rates.factors.overheadPct
        option.profitPct = rates.factors.profitPct
        option.scope = Estimator.scope(sample, takeoff: Takeoff())
        var estimate = Estimate()
        estimate.options = [option]
        estimate.selectedOptionID = option.id
        estimates[id] = estimate
        markDirty(.estimate(id))
    }

    func resetPracticeJob() {
        guard let job = practiceJob else { return }
        deleteJob(job.id)
        ensurePracticeJob()
    }

    // MARK: - Weather and backups

    func refreshWeather(force: Bool = false) {
        guard let lat = settings.company.homeLatitude, let lon = settings.company.homeLongitude else { return }
        let model = weather
        Task { await model.refresh(lat: lat, lon: lon, force: force) }
    }

    func runBackupIfDue(force: Bool = false) {
        guard let root = dataFolder else { return }
        if !force {
            guard settings.backupNightly else { return }
            if let last = settings.lastBackup, Date.now.timeIntervalSince(last) < 20 * 3600 { return }
        }
        let local = localBackupsFolder(for: root)
        Task.detached(priority: .background) {
            let result = Result { try Backup.make(of: root, localCopies: local) }
            await MainActor.run {
                guard self.dataFolder == root else { return }
                switch result {
                case .success:
                    self.settings.lastBackup = .now
                    self.markDirty(.settings)
                case .failure(SafeFile.Failure.notResponding):
                    self.problem = "\(Self.backupWaitingPrefix) iCloud Drive isn't responding. It runs again by itself when iCloud answers."
                case .failure(let error):
                    self.problem = "Backup didn't finish: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Notices

    /// Adds to Recent activity (Settings › Data & backups) and, unless a banner already says it, shows it briefly.
    func notify(_ text: String, toast showToast: Bool = true) {
        notices.removeAll { $0 == text }
        notices.insert(text, at: 0)
        if notices.count > 20 { notices.removeLast(notices.count - 20) }
        if showToast { toast = text }
    }

    // MARK: - Tour

    func startTour() {
        ensurePracticeJob()
        goTo(.today)
    }

    func goTo(_ stop: TourStop) {
        tourStop = stop
        switch stop {
        case .today: selection = .today
        case .pipeline: selection = .pipeline
        case .measure:
            let job = ensurePracticeJob()
            openJob(job.id, tab: .measure)
        case .estimate:
            let job = ensurePracticeJob()
            seedPracticeEstimate(job.id)
            openJob(job.id, tab: .estimate)
        case .schedule: selection = .schedule
        case .settings: selection = .settings
        }
    }

    func endTour(completed: Bool) {
        tourStop = nil
        if completed {
            settings.tourCompleted = true
            markDirty(.settings)
            selection = .today
        }
    }
}
