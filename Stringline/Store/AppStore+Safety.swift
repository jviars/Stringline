import Foundation
import AppKit

/// The parts of the store that keep data safe: noticing changes made elsewhere, clashes,
/// restoring from History, the one-Mac-at-a-time lock, and the health check.
extension AppStore {

    // MARK: - Remembering what's on disk

    func remember(_ rel: String, _ data: Data, extras extra: JSONFile.Extras, reason: Journal.Reason, label: String) {
        guard let root = dataFolder else { return }
        records[rel] = FileRecord(sha: SafeFile.sha256(data), stamp: SafeFile.stamp(root.appending(path: rel)))
        extras[rel] = extra.isEmpty ? nil : extra
        unavailable[rel] = nil
        journal?.record(rel, data, reason: reason, label: label)
    }

    /// A file that can't be read is set aside (never deleted), and the newest good copy from History goes back in its place.
    func restoreDamaged<T: Codable & DefaultInit>(_ rel: String, bytes: Data, root: URL, journal: Journal?, as type: T.Type, label: String) -> T? {
        guard let journal,
              let (version, good) = journal.latestGood(rel, accept: { JSONFile.decode(T.self, from: $0) != nil }),
              case .ok(let value, let data, let extra) = JSONFile.interpret(T.self, good) else { return nil }
        setAside(bytes, as: rel, label: label, journal: journal)
        do {
            try SafeFile.write(data, to: root.appending(path: rel))
        } catch {
            return nil
        }
        records[rel] = FileRecord(sha: SafeFile.sha256(data), stamp: SafeFile.stamp(root.appending(path: rel)))
        extras[rel] = extra.isEmpty ? nil : extra
        unavailable[rel] = nil
        journal.record(rel, data, reason: .restored, label: label)
        notify("\(label) couldn't be read, so Stringline put back the copy saved \(Self.when(version.savedAt)). The damaged file was set aside on this Mac.")
        return value
    }

    /// Keeps bytes that are being replaced in ~/Library/Application Support/Stringline/Set Aside, and in History.
    func setAside(_ data: Data, as rel: String, label: String, journal: Journal? = nil) {
        let destination = setAsideFolder.appending(path: Self.setAsideStamp()).appending(path: rel)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SafeFile.write(data, to: destination)
        (journal ?? self.journal)?.record(rel, data, reason: .setAside, label: label)
    }

    /// Moves a file out of the PavingData folder into Set Aside (used for iCloud's extra copies).
    func setAsideFile(_ rel: String) {
        guard let root = dataFolder else { return }
        let source = root.appending(path: rel)
        if case .bytes(let data) = SafeFile.read(source) {
            journal?.record(DataFile.conflictOriginal(of: rel) ?? rel, data, reason: .setAside, label: "iCloud copy of \(rel)")
        }
        let destination = setAsideFolder.appending(path: Self.setAsideStamp()).appending(path: rel)
        do {
            try SafeFile.move(source, to: destination)
        } catch {
            problem = "Couldn't move \(rel) out of the way: \(error.localizedDescription)"
        }
    }

    private static func setAsideStamp() -> String {
        Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                     timeZone: .current, calendar: .current))
    }

    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today at \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday at \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    func announceUnavailable() {
        let downloading = unavailable.values.filter { $0 == .downloading }.count
        if downloading > 0 {
            notify(downloading == 1
                   ? "1 file is still downloading from iCloud. It'll open by itself when it arrives, and nothing is changed until then."
                   : "\(downloading) files are still downloading from iCloud. They'll open by themselves when they arrive, and nothing is changed until then.")
        }
        let others = unavailable.filter { $0.value != .downloading }
        for (rel, issue) in others.sorted(by: { $0.key < $1.key }) {
            let name = DataFile(path: rel).map { label(for: $0) } ?? rel
            notify("\(name) is \(issue.short). Stringline won't change it.")
        }
    }

    // MARK: - Watching the folder

    func startWatching() {
        guard let root = dataFolder else { return }
        watcher?.stop()
        watcher = FolderWatcher(folder: root) { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
        if syncObserver == nil {
            syncObserver = NotificationCenter.default.addObserver(forName: SafeFile.syncRecovered, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncCameBack() }
            }
        }
    }

    /// iCloud answers again after not responding: save what was waiting and re-read anything that couldn't be read.
    func syncCameBack() {
        guard dataFolder != nil else { return }
        flush()
        scheduleRescan()
        // A backup that couldn't finish while iCloud was stuck is still due: clear the message and run it now.
        if problem?.hasPrefix(Self.backupWaitingPrefix) == true {
            problem = nil
            runBackupIfDue()
        }
    }

    func scheduleRescan(after seconds: Double = 0.4) {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    /// Compares every file with what was last seen and brings memory up to date.
    /// Changes made elsewhere are loaded; if this Mac has unsaved changes to the same file, the two go to the person to choose.
    func rescan() {
        guard let root = dataFolder, launchProblem == nil else { return }
        let listing = DataFile.list(root)
        let candidates = listing.files.union(listing.placeholders).union(records.keys).union(unavailable.keys)
        // Settings and job details first, so a new job exists before its other files are read.
        func rank(_ path: String) -> Int {
            switch DataFile(path: path) {
            case .settings, .rates: 0
            case .customer: 1
            case .job(_, .job): 2
            default: 3
            }
        }
        var changed = false
        for rel in candidates.sorted(by: { (rank($0), $0) < (rank($1), $1) }) where reconcile(rel, root: root) {
            changed = true
        }
        if changed {
            jobs.sort { $0.created > $1.created }
            customers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        handleICloudCopies(listing)
    }

    /// Returns true if memory changed.
    @discardableResult
    func reconcile(_ rel: String, root: URL) -> Bool {
        guard let file = DataFile(path: rel) else { return false }
        if let folder = file.jobFolder, duplicateFolders[folder] != nil { return false }
        // Waiting on the person to choose between two versions: leave both exactly as they are.
        if conflicts.contains(where: { $0.path == rel }) { return false }
        let url = root.appending(path: rel)
        let stamp = SafeFile.stamp(url)
        if let record = records[rel], unavailable[rel] == nil, let stamp, record.stamp == stamp { return false }
        let key = key(for: file)
        if case .job(_, let part) = file, part != .job, key == nil { return false }
        let label = label(for: file)

        switch SafeFile.read(url) {
        case .missing:
            let hadIt = records[rel] != nil
            unavailable[rel] = nil
            guard hadIt else { return false }
            if let key, pending.contains(key), let mine = try? encodedValue(for: key, path: rel) {
                raiseConflict(file, mine: mine, theirs: nil, theirsDate: nil, source: .changedElsewhere)
                return true
            }
            records[rel] = nil
            extras[rel] = nil
            applyRemoval(file, label: label)
            return true
        case .notDownloaded:
            // Evicted after it was read here: memory still has it. Otherwise wait for the download.
            if records[rel] == nil { unavailable[rel] = .downloading }
            return false
        case .notResponding:
            if records[rel] == nil { unavailable[rel] = .syncNotResponding }
            return false
        case .unreadable(let why):
            if records[rel] == nil { unavailable[rel] = .unreadable(why) }
            return false
        case .bytes(let data):
            let sha = SafeFile.sha256(data)
            if records[rel]?.sha == sha, unavailable[rel] == nil {
                records[rel]?.stamp = stamp
                return false
            }
            guard let parsed = parse(file, data) else {
                return handleDamagedChange(file, rel: rel, bytes: data, key: key, label: label)
            }
            if parsed.newer {
                if let key, pending.contains(key), let mine = try? encodedValue(for: key, path: rel) {
                    journal?.record(rel, mine, reason: .unsaved, label: label)
                    pending.remove(key)
                    notify("\(label) was saved by a newer Stringline on another Mac, so this Mac's change to it was kept in History instead.")
                }
                unavailable[rel] = .newerVersion
                return true
            }
            if let key, pending.contains(key) {
                if let mine = try? encodedValue(for: key, path: rel), mine == data {
                    records[rel] = FileRecord(sha: sha, stamp: stamp)
                    pending.remove(key)
                    return false
                }
                if let mine = try? encodedValue(for: key, path: rel) {
                    raiseConflict(file, mine: mine, theirs: data, theirsDate: SafeFile.modified(url), source: .changedElsewhere)
                    return true
                }
            }
            let wasWaiting = unavailable[rel] != nil
            let isNew = records[rel] == nil
            guard apply(file, data) else { return false }
            remember(rel, data, extras: parsed.extras, reason: isNew && !wasWaiting ? .loaded : .external, label: self.label(for: file))
            if wasWaiting {
                notify("\(self.label(for: file)) finished downloading.")
            }
            return true
        }
    }

    /// A file that was fine is now unreadable. If memory has the good version, put it back; otherwise try History.
    private func handleDamagedChange(_ file: DataFile, rel: String, bytes: Data, key: SaveKey?, label: String) -> Bool {
        guard let root = dataFolder else { return false }
        if records[rel] != nil, let key, let mine = try? encodedValue(for: key, path: rel) {
            setAside(bytes, as: rel, label: label)
            do {
                try SafeFile.write(mine, to: root.appending(path: rel))
                records[rel] = FileRecord(sha: SafeFile.sha256(mine), stamp: SafeFile.stamp(root.appending(path: rel)))
                notify("\(label) was damaged outside Stringline, so the good copy was put back. The damaged file was set aside on this Mac.")
            } catch {
                problem = "Couldn't repair \(label): \(error.localizedDescription)"
            }
            return true
        }
        if restoreFromHistory(file, bytes: bytes) { return true }
        unavailable[rel] = .damaged
        return true
    }

    private func restoreFromHistory(_ file: DataFile, bytes: Data) -> Bool {
        guard let root = dataFolder, let journal else { return false }
        let rel = file.path
        let label = label(for: file)
        guard let (version, good) = journal.latestGood(rel, accept: { self.parse(file, $0)?.newer == false }) else { return false }
        setAside(bytes, as: rel, label: label)
        do {
            try SafeFile.write(good, to: root.appending(path: rel))
        } catch {
            problem = "Couldn't repair \(label): \(error.localizedDescription)"
            return false
        }
        guard apply(file, good) else { return false }
        remember(rel, good, extras: parse(file, good)?.extras ?? [:], reason: .restored, label: label)
        notify("\(label) couldn't be read, so Stringline put back the copy saved \(Self.when(version.savedAt)). The damaged file was set aside on this Mac.")
        return true
    }

    /// Decodes a file's bytes as whatever kind of file it is.
    func parse(_ file: DataFile, _ data: Data) -> (extras: JSONFile.Extras, newer: Bool)? {
        func check<T: Codable & DefaultInit>(_ type: T.Type) -> (JSONFile.Extras, Bool)? {
            switch JSONFile.interpret(T.self, data) {
            case .ok(_, _, let extra): (extra, false)
            case .newer: ([:], true)
            default: nil
            }
        }
        switch file {
        case .settings: return check(AppSettings.self)
        case .rates: return check(Rates.self)
        case .customer: return check(Customer.self)
        case .job(_, let part):
            switch part {
            case .job: return check(Job.self)
            case .takeoff: return check(Takeoff.self)
            case .estimate: return check(Estimate.self)
            case .logs: return check(JobLogs.self)
            case .invoice: return check(Invoice.self)
            }
        }
    }

    /// Puts a file's contents into memory. Returns false if it doesn't decode or doesn't fit.
    @discardableResult
    func apply(_ file: DataFile, _ data: Data) -> Bool {
        switch file {
        case .settings:
            guard let value = JSONFile.decode(AppSettings.self, from: data) else { return false }
            settings = value
        case .rates:
            guard let value = JSONFile.decode(Rates.self, from: data) else { return false }
            rates = value
        case .customer:
            guard let value = JSONFile.decode(Customer.self, from: data) else { return false }
            if let i = customers.firstIndex(where: { $0.id == value.id }) { customers[i] = value } else { customers.append(value) }
        case .job(let folder, .job):
            guard var value = JSONFile.decode(Job.self, from: data) else { return false }
            value.folderName = folder
            if let i = jobs.firstIndex(where: { $0.id == value.id }) {
                guard jobs[i].folderName == folder else {
                    duplicateFolders[folder] = jobs[i].folderName
                    return false
                }
                jobs[i] = value
            } else {
                jobs.append(value)
                if takeoffs[value.id] == nil { takeoffs[value.id] = Takeoff() }
                if estimates[value.id] == nil { estimates[value.id] = Estimate() }
                if logs[value.id] == nil { logs[value.id] = JobLogs() }
            }
        case .job(let folder, let part):
            guard let id = jobID(inFolder: folder) else { return false }
            switch part {
            case .job: return false
            case .takeoff:
                guard let value = JSONFile.decode(Takeoff.self, from: data) else { return false }
                takeoffs[id] = value
            case .estimate:
                guard let value = JSONFile.decode(Estimate.self, from: data) else { return false }
                estimates[id] = value
            case .logs:
                guard let value = JSONFile.decode(JobLogs.self, from: data) else { return false }
                logs[id] = value
            case .invoice:
                guard let value = JSONFile.decode(Invoice.self, from: data) else { return false }
                invoices[id] = value
            }
        }
        return true
    }

    /// A file disappeared from the folder (deleted on another Mac, or by hand).
    func applyRemoval(_ file: DataFile, label: String) {
        switch file {
        case .settings, .rates:
            // Stringline can't run without these: write this Mac's copy back.
            if let key = key(for: file) { markDirty(key) }
            notify("\(label) went missing from the folder, so this Mac's copy was saved again.")
        case .customer(let id):
            customers.removeAll { $0.id == id }
        case .job(let folder, .job):
            guard let id = jobID(inFolder: folder), let job = job(id) else { return }
            for key in [SaveKey.job(id), .takeoff(id), .estimate(id), .logs(id), .invoice(id)] { pending.remove(key) }
            for part in JobPart.allCases where part != .job {
                records["jobs/\(folder)/\(part.fileName)"] = nil
                unavailable["jobs/\(folder)/\(part.fileName)"] = nil
            }
            jobs.removeAll { $0.id == id }
            takeoffs[id] = nil; estimates[id] = nil; logs[id] = nil; invoices[id] = nil
            recentJobIDs.removeAll { $0 == id }
            if case .job(let open) = selection, open == id { selection = .jobs }
            notify("\(job.name) was removed from the PavingData folder outside Stringline. You can bring it back from History.")
        case .job(let folder, let part):
            guard let id = jobID(inFolder: folder) else { return }
            switch part {
            case .job: break
            case .takeoff: takeoffs[id] = Takeoff()
            case .estimate: estimates[id] = Estimate()
            case .logs: logs[id] = JobLogs()
            case .invoice: invoices[id] = nil
            }
        }
    }

    // MARK: - Clashes

    func raiseConflict(_ file: DataFile, mine: Data?, theirs: Data?, theirsDate: Date?, source: DataConflict.Source) {
        let rel = file.path
        if let key = key(for: file) { pending.remove(key) }
        guard !conflicts.contains(where: { $0.path == rel && $0.source == source }) else { return }
        let label = label(for: file)
        if let mine { journal?.record(rel, mine, reason: .conflictMine, label: label) }
        if let theirs { journal?.record(rel, theirs, reason: .external, label: label) }
        conflicts.append(DataConflict(path: rel, title: label, source: source, mine: mine, mineDate: .now, theirs: theirs, theirsDate: theirsDate))
    }

    /// iCloud keeps both sides of a clash by saving a copy named like "estimate 2.json".
    func handleICloudCopies(_ listing: DataFile.Listing) {
        guard let root = dataFolder else { return }
        for copy in listing.lockCopies { try? SafeFile.remove(root.appending(path: copy)) }
        for (rel, copies) in listing.copies.sorted(by: { $0.key < $1.key }) {
            guard let file = DataFile(path: rel), unavailable[rel] == nil else { continue }
            if let folder = file.jobFolder, duplicateFolders[folder] != nil || jobID(inFolder: folder) == nil { continue }
            for copy in copies.sorted() where !conflicts.contains(where: { $0.source == .iCloudCopy(copy) }) {
                guard case .bytes(let theirs) = SafeFile.read(root.appending(path: copy)) else { continue }
                let current: Data? = key(for: file).flatMap { try? encodedValue(for: $0, path: rel) }
                if parse(file, theirs) == nil || current == theirs {
                    // Unreadable or identical: nothing to choose. Keep it in History and move it out of the way.
                    setAsideFile(copy)
                    continue
                }
                raiseConflict(file, mine: current, theirs: theirs, theirsDate: SafeFile.modified(root.appending(path: copy)), source: .iCloudCopy(copy))
            }
        }
    }

    /// Settles a clash. The version not chosen stays in History.
    func resolve(_ conflict: DataConflict, keepMine: Bool) {
        guard let root = dataFolder, let file = DataFile(path: conflict.path) else { return }
        conflicts.removeAll { $0.id == conflict.id }
        let rel = conflict.path
        let url = root.appending(path: rel)
        if keepMine {
            if conflict.theirs == nil, case .job(let folder, _) = file, let id = jobID(inFolder: folder) {
                // The job was deleted elsewhere: bring the whole job back from this Mac.
                for part in JobPart.allCases { records["jobs/\(folder)/\(part.fileName)"] = nil }
                for key in [SaveKey.job(id), .takeoff(id), .estimate(id), .logs(id)] { pending.insert(key) }
                if invoices[id] != nil { pending.insert(.invoice(id)) }
            } else if let key = key(for: file) {
                if case .bytes(let disk) = SafeFile.read(url) {
                    records[rel] = FileRecord(sha: SafeFile.sha256(disk), stamp: SafeFile.stamp(url))
                }
                pending.insert(key)
            }
            flush()
        } else if let theirs = conflict.theirs {
            apply(file, theirs)
            if case .iCloudCopy = conflict.source {
                do {
                    journal?.record(rel, theirs, reason: .unsaved, label: conflict.title)
                    try SafeFile.write(theirs, to: url)
                } catch {
                    problem = "Couldn't save the version you chose: \(error.localizedDescription)"
                }
            }
            remember(rel, theirs, extras: parse(file, theirs)?.extras ?? [:], reason: .saved, label: conflict.title)
            if let key = key(for: file) { pending.remove(key) }
        } else {
            records[rel] = nil
            applyRemoval(file, label: conflict.title)
        }
        if case .iCloudCopy(let copy) = conflict.source { setAsideFile(copy) }
    }

    // MARK: - History

    struct HistoryItem: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let file: DataFile?
        let title: String
        let group: String
        let lastSaved: Date
        let versions: Int
        let isGone: Bool
    }

    func historyItems() -> [HistoryItem] {
        guard let journal, let root = dataFolder else { return [] }
        return journal.latestVersions().map { version in
            let file = DataFile(path: version.path)
            let onDisk = SafeFile.exists(root.appending(path: version.path))
            let title = file.map { onDisk || $0.jobFolder.flatMap(jobID(inFolder:)) != nil ? label(for: $0) : version.label } ?? version.label
            let group: String = switch file {
            case .settings, .rates: "Company"
            case .customer: "Customers"
            case .job(let folder, _): jobID(inFolder: folder).flatMap { job($0)?.name } ?? version.label.components(separatedBy: " · ").first ?? folder
            case nil: "Other"
            }
            return HistoryItem(path: version.path, file: file, title: title, group: group, lastSaved: version.savedAt,
                               versions: journal.versions(of: version.path).count, isGone: !onDisk)
        }
    }

    func versions(of path: String) -> [Journal.Version] { journal?.versions(of: path) ?? [] }

    func versionData(_ version: Journal.Version) -> Data? { journal?.data(version.id) }

    /// Puts an earlier version back. Whatever is there now stays in History too.
    func restore(_ version: Journal.Version) throws {
        guard let root = dataFolder, let file = DataFile(path: version.path), let data = journal?.data(version.id) else {
            throw FolderError.couldNotOpen("That version couldn't be read from History.")
        }
        guard parse(file, data) != nil else { throw FolderError.couldNotOpen("That version can't be read, so it can't be restored.") }
        if case .job(let folder, let part) = file, part != .job, jobID(inFolder: folder) == nil {
            // Restoring part of a job that's gone: bring the job back first.
            if let job = journal?.versions(of: "jobs/\(folder)/job.json").first { try restore(job) }
        }
        let url = root.appending(path: version.path)
        if case .bytes(let current) = SafeFile.read(url) {
            journal?.record(version.path, current, reason: .external, label: version.label)
        }
        try SafeFile.write(data, to: url)
        conflicts.removeAll { $0.path == version.path }
        apply(file, data)
        remember(version.path, data, extras: parse(file, data)?.extras ?? [:], reason: .restored, label: label(for: file))
        if let key = key(for: file) { pending.remove(key) }
        unsavedLastTime.removeAll { $0.path == version.path }
        jobs.sort { $0.created > $1.created }
        customers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        notify("Restored \(label(for: file)) to the version from \(Self.when(version.savedAt)).")
    }

    /// Brings back a job whose folder is gone, with each of its files at their newest version in History.
    func restoreJob(folder: String) throws {
        guard let journal, let root = dataFolder else { return }
        guard let newest = journal.versions(of: "jobs/\(folder)/job.json").first(where: { $0.reason != .setAside }) else {
            throw FolderError.couldNotOpen("There's no saved copy of that job on this Mac.")
        }
        let deletedAt = newest.reason == .deleted ? newest.savedAt : nil
        try restore(newest)
        for part in JobPart.allCases where part != .job {
            let path = "jobs/\(folder)/\(part.fileName)"
            guard !SafeFile.exists(root.appending(path: path)),
                  let version = journal.versions(of: path).first(where: { $0.reason != .setAside }) else { continue }
            // Skip a file that was removed on its own before the job was deleted (like an invoice taken off).
            if version.reason == .deleted, let deletedAt, abs(version.savedAt.timeIntervalSince(deletedAt)) > 120 { continue }
            try? restore(version)
        }
        if let id = jobID(inFolder: folder), let dir = job(id).flatMap(jobFolder) {
            for sub in ["photos", "docs"] {
                try? FileManager.default.createDirectory(at: dir.appending(path: sub, directoryHint: .isDirectory), withIntermediateDirectories: true)
            }
        }
    }

    /// "It was deleted on purpose": stops listing a missing job or file.
    func forgetMissing(paths: [String]) {
        guard let journal else { return }
        for path in paths {
            if let newest = journal.versions(of: path).first, let data = journal.data(newest.id) {
                journal.record(path, data, reason: .deleted, label: newest.label)
            }
        }
        checkHealth()
    }

    func dismissUnsaved(_ version: Journal.Version) {
        journal?.mark(version.id, as: .discarded)
        unsavedLastTime.removeAll { $0.id == version.id }
        checkHealth()
    }

    // MARK: - One Mac at a time

    func acquireLock() {
        guard let root = dataFolder else { return }
        let lock = FolderLock(folder: root, machineID: machineID, machineName: machineName)
        self.lock = lock
        if let other = lock.otherOwner() {
            savingPaused = other
            showLockPrompt = true
        } else {
            do { try lock.claim() } catch { problem = "Couldn't mark the folder as in use: \(error.localizedDescription)" }
        }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(FolderLock.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.heartbeat()
            }
        }
    }

    func heartbeat() {
        guard let lock, dataFolder != nil else { return }
        if let paused = savingPaused {
            if lock.otherOwner() == nil {
                // The other Mac closed Stringline (or went quiet for a while): carry on here.
                takeOver()
                notify("\(paused.machineName) isn't using Stringline anymore, so this Mac is saving again.")
            }
        } else if let other = (try? lock.beat()) ?? nil {
            pause(for: other)
        }
        if !unavailable.isEmpty || !pending.isEmpty { rescan() }
    }

    func pause(for other: LockInfo) {
        guard savingPaused == nil else { return }
        savingPaused = other
        notify("\(other.machineName) started using Stringline, so saving is paused on this Mac.", toast: false)
    }

    /// "Use this Mac": loads anything the other Mac saved, takes the lock, then saves what's waiting here.
    func takeOver() {
        rescan()
        do { try lock?.claim() } catch { problem = "Couldn't mark the folder as in use: \(error.localizedDescription)" }
        savingPaused = nil
        showLockPrompt = false
        flush()
    }

    // MARK: - Health check

    /// Checks every file. `deep` re-reads all of them, not just the ones that look changed.
    func checkHealth(deep: Bool = false) {
        guard let root = dataFolder else { return }
        if deep {
            for rel in records.keys { records[rel]?.stamp = nil }
        }
        rescan()
        var issues: [HealthIssue] = []
        for (rel, issue) in unavailable.sorted(by: { $0.key < $1.key }) {
            let name = DataFile(path: rel).map { label(for: $0) } ?? rel
            issues.append(HealthIssue(kind: .file(rel, issue), title: "\(name) is \(issue.short)", detail: issue.explanation))
        }
        for conflict in conflicts {
            issues.append(HealthIssue(kind: .conflict(conflict.id), title: "Two versions of \(conflict.title)",
                                      detail: "Choose which one to keep. The other stays in History."))
        }
        for (copy, original) in duplicateFolders.sorted(by: { $0.key < $1.key }) {
            issues.append(HealthIssue(kind: .duplicateFolder(copy, original: original), title: "A second copy of a job folder",
                                      detail: "\"\(copy)\" is a copy iCloud made of \"\(original)\". Stringline uses the original and leaves the copy alone."))
        }
        for version in unsavedLastTime {
            issues.append(HealthIssue(kind: .unsavedLastTime(version.id, path: version.path), title: "\(version.label): a change that wasn't saved",
                                      detail: "From \(Self.when(version.savedAt)). It's kept on this Mac. Restore it, or dismiss it to keep what's in the folder."))
        }
        // Files History knows about that vanished without Stringline deleting them.
        var missingJobs: Set<String> = []
        for version in journal?.latestVersions() ?? [] where ![.deleted, .setAside, .discarded].contains(version.reason) {
            guard let file = DataFile(path: version.path), !SafeFile.exists(root.appending(path: version.path)) else { continue }
            switch file {
            case .job(let folder, let part):
                if duplicateFolders[folder] != nil { continue }
                if jobID(inFolder: folder) == nil {
                    // The whole job is gone: one line for the job, not one per file.
                    if part == .job { missingJobs.insert(folder) }
                    continue
                }
            case .customer(let id):
                if customers.contains(where: { $0.id == id }) { continue }
            case .settings, .rates:
                break
            }
            issues.append(HealthIssue(kind: .missingFile(version.path), title: "\(version.label) is missing from the folder",
                                      detail: "It wasn't deleted in Stringline. Restore it from History, or dismiss if it was removed on purpose."))
        }
        for folder in missingJobs.sorted() {
            let name = journal?.versions(of: "jobs/\(folder)/job.json").first?.label.components(separatedBy: " · ").first ?? folder
            issues.append(HealthIssue(kind: .missingJob(folder: folder), title: "\(name) is missing from the folder",
                                      detail: "This job's folder is gone, but it wasn't deleted in Stringline. Restore it from History, or dismiss if it was removed on purpose."))
        }
        if let other = savingPaused {
            issues.append(HealthIssue(kind: .otherMac, title: "Saving is paused", detail: "Stringline is open on \(other.machineName). Choose Use This Mac to save here instead."))
        }
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let free, free < 1_000_000_000 {
            issues.append(HealthIssue(kind: .lowDisk, title: "This Mac is almost out of space",
                                      detail: "Only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. Saving needs a little room to work safely."))
        }
        if let problem = journal?.problem {
            issues.append(HealthIssue(kind: .history, title: "History needs attention", detail: problem))
        }
        let localBackups = ((try? FileManager.default.contentsOfDirectory(atPath: localBackupsFolder(for: root).path)) ?? []).filter { $0.hasSuffix(".zip") }.count
        health = HealthReport(checkedAt: .now, files: records.count, issues: issues, historyVersions: journal?.count ?? 0,
                              localBackups: localBackups, freeSpace: free)
    }

    /// From the problem screen: replace a damaged or missing settings file with defaults. Jobs and customers are untouched.
    func rebuildSettings(in folder: URL) {
        let url = folder.appending(path: "settings.json")
        if case .bytes(let old) = SafeFile.read(url) {
            let aside = setAsideFolder.appending(path: Self.setAsideStamp()).appending(path: "settings.json")
            try? FileManager.default.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? SafeFile.write(old, to: aside)
        }
        var fresh = AppSettings()
        fresh.onboardingComplete = true
        do {
            try SafeFile.write(JSONFile.encode(fresh, name: "settings.json"), to: url)
        } catch {
            problem = "Couldn't write new settings: \(error.localizedDescription)"
            return
        }
        openFolder(folder)
        if dataFolder != nil {
            notify("Settings were reset to the defaults. Your jobs, customers and rates are untouched. Check Settings › Company.")
        }
    }

    // MARK: - Quitting

    /// Changes that couldn't be written yet (saving paused, or the folder can't be reached).
    var hasUnsavedChanges: Bool { !pending.isEmpty }

    /// Keeps whatever couldn't be saved in History, so it can be restored next time.
    func keepUnsavedInHistory() {
        for key in pending {
            guard let file = file(for: key), let data = try? encodedValue(for: key, path: file.path) else { continue }
            journal?.record(file.path, data, reason: .unsaved, label: label(for: file))
        }
        pending.removeAll()
    }

    func shutDown() {
        flush()
        if hasUnsavedChanges { keepUnsavedInHistory() }
        closeFolder()
    }
}
