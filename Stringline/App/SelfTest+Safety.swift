#if DEBUG
import SwiftUI
import AppKit

/// End-to-end checks that the real app never loses or overwrites data:
/// damaged and offloaded files, changes from another Mac, iCloud's copies, failed saves and the one-Mac lock.
extension SelfTest {
    static func runSafety(store: AppStore, folder: URL) async {
        let fm = FileManager.default
        lines.append("")
        lines.append("-- Data safety")
        FolderLock.interval = 1
        FolderLock.staleAfter = 8
        store.acquireLock()
        store.flush()

        func path(_ rel: String) -> URL { folder.appending(path: rel) }
        func bytes(_ rel: String) -> Data? { try? Data(contentsOf: path(rel)) }
        func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                await pause(0.1)
            }
            return condition()
        }
        /// Another program (iCloud bringing in another Mac's change, or a person in Finder) writing a file.
        func writeFromElsewhere<T: Encodable>(_ value: T, _ rel: String) {
            let data = (try? JSONFile.encoder.encode(value)) ?? Data()
            try? data.write(to: path(rel), options: .atomic)
        }
        func snapshotSheet(_ name: String) {
            guard let sheet = window?.attachedSheet, let view = sheet.contentView else { return snapshot(name) }
            shot += 1
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let screens = outputFolder.appending(path: "screens", directoryHint: .isDirectory)
            try? rep.representation(using: .png, properties: [:])?.write(to: screens.appending(path: String(format: "%02d-%@.png", shot, name)))
        }
        func reopen() {
            store.openFolder(folder)
        }

        guard let jobA = store.realJobs.first(where: { $0.name == "Maple Ridge Plaza" }),
              let jobB = store.realJobs.first(where: { $0.name == "Hillcrest Apartments" }),
              let jobC = store.realJobs.first(where: { $0.name == "Riverbend Elementary" }) else {
            check("Safety tests have their sample jobs", false)
            return
        }
        let a = "jobs/\(jobA.folderName)"
        let b = "jobs/\(jobB.folderName)"
        let c = "jobs/\(jobC.folderName)"

        // 1. A damaged file is restored from History automatically, and the damaged copy is kept.
        let shapesBefore = store.takeoffs[jobA.id]?.shapes.count ?? 0
        let goodTakeoff = bytes("\(a)/takeoff.json")
        let garbage = Data((goodTakeoff ?? Data()).prefix(37))
        try? garbage.write(to: path("\(a)/takeoff.json"))
        reopen()
        let setAsideHasIt = (fm.enumerator(atPath: store.setAsideFolder.path)?.allObjects as? [String] ?? [])
            .contains { $0.hasSuffix("takeoff.json") && (try? Data(contentsOf: store.setAsideFolder.appending(path: $0))) == garbage }
        check("A damaged file is put back from History when Stringline opens",
              store.takeoffs[jobA.id]?.shapes.count == shapesBefore && shapesBefore > 0 && bytes("\(a)/takeoff.json") == goodTakeoff,
              "\(store.takeoffs[jobA.id]?.shapes.count ?? -1) of \(shapesBefore) shapes")
        check("The damaged copy is kept in Set Aside, not deleted", setAsideHasIt)
        check("The person is told what happened", store.notices.contains { $0.contains("couldn't be read") })

        // 2. A damaged file with no good copy anywhere is never written over.
        let junk = Data("{\"amountCents\": 12".utf8)
        try? junk.write(to: path("\(c)/invoice.json"))
        reopen()
        check("A damaged file with no earlier copy is marked, not replaced", store.unavailable["\(c)/invoice.json"] == .damaged)
        var attempt = Invoice(); attempt.number = "9999"
        store.invoiceBinding(jobC.id).wrappedValue = attempt
        store.flush()
        await pause(0.8)
        check("Editing it is refused and the file stays exactly as it was", bytes("\(c)/invoice.json") == junk && store.problem != nil)
        store.problem = nil
        store.openJob(jobC.id, tab: .invoice)
        await pause(1)
        snapshot("safety-damaged-file")
        try? fm.removeItem(at: path("\(c)/invoice.json"))
        store.rescan()
        store.invoices[jobC.id] = nil
        check("Once the damaged file is gone, the job is editable again", store.unavailable.isEmpty, "\(store.unavailable)")

        // 3. A file iCloud hasn't downloaded (Optimize Mac Storage) is never written over.
        let estimatePath = path("\(a)/estimate.json")
        let estimateBefore = bytes("\(a)/estimate.json")
        SafeFile.simulatedNotDownloaded = [estimatePath.standardizedFileURL.path]
        reopen()
        check("A file that's still in iCloud is marked as downloading", store.unavailable["\(a)/estimate.json"] == .downloading)
        store.openJob(jobA.id, tab: .estimate)
        await pause(1)
        snapshot("safety-downloading")
        var blank = Estimate(); blank.proposalNumber = "SHOULD-NOT-SAVE"
        store.estimateBinding(jobA.id).wrappedValue = blank
        store.flush()
        check("Nothing is saved over a file that hasn't downloaded", bytes("\(a)/estimate.json") == estimateBefore)
        store.problem = nil
        SafeFile.simulatedNotDownloaded = []
        let arrived = await waitFor(4) { store.unavailable.isEmpty }
        check("When the download finishes, the real file opens by itself",
              arrived && json(store.estimates[jobA.id]) == json(JSONFile.read(Estimate.self, from: estimatePath)) && store.estimates[jobA.id]?.proposalNumber != "SHOULD-NOT-SAVE")

        // Older iCloud: a ".logs.json.icloud" placeholder in place of the file.
        let logsURL = path("\(a)/logs.json")
        let logsBefore = bytes("\(a)/logs.json")
        let parked = outputFolder.appending(path: "parked-logs.json")
        try? fm.removeItem(at: parked)
        try? fm.moveItem(at: logsURL, to: parked)
        try? Data().write(to: SafeFile.placeholder(for: logsURL))
        reopen()
        store.logsBinding(jobA.id).wrappedValue = JobLogs()
        store.flush()
        check("A placeholder file is treated as downloading, and no empty file is created in its place",
              store.unavailable["\(a)/logs.json"] == .downloading && !fm.fileExists(atPath: logsURL.path))
        store.problem = nil
        try? fm.moveItem(at: parked, to: logsURL)
        try? fm.removeItem(at: SafeFile.placeholder(for: logsURL))
        let logsBack = await waitFor(4) { store.unavailable.isEmpty }
        check("The daily logs come back intact once downloaded", logsBack && bytes("\(a)/logs.json") == logsBefore && (store.logs[jobA.id]?.entries.count ?? 0) == 1)

        // 4. Launch problems never fall through to setup.
        let settingsURL = path("settings.json")
        let settingsBytes = bytes("settings.json")
        store.closeFolder()
        SafeFile.simulatedNotDownloaded = [settingsURL.standardizedFileURL.path]
        store.openFolder(folder)
        check("If settings haven't downloaded yet, Stringline waits instead of starting setup",
              store.launchProblem == .settingsDownloading(folder) && !store.needsOnboarding && bytes("settings.json") == settingsBytes)
        await pause(1)
        snapshot("safety-waiting-for-icloud")
        SafeFile.simulatedNotDownloaded = []
        let opened = await waitFor(6) { store.launchProblem == nil && store.dataFolder != nil }
        check("…and opens by itself as soon as they arrive", opened && store.settings.company.name == "Test Paving Co")

        let nowhere = outputFolder.appending(path: "Not There/PavingData", directoryHint: .isDirectory)
        store.openFolder(nowhere)
        check("A missing folder shows a problem screen and nothing is created there",
              store.launchProblem == .folderMissing(nowhere) && !fm.fileExists(atPath: nowhere.path))
        await pause(1)
        snapshot("safety-folder-missing")
        store.openFolder(folder)

        try? Data("{\"company\": {\"name\": ".utf8).write(to: settingsURL)
        store.openFolder(folder)
        check("Damaged settings are put back from History automatically",
              store.launchProblem == nil && store.settings.company.name == "Test Paving Co" && store.settings.onboardingComplete)

        let copy = outputFolder.appending(path: "PavingData copy", directoryHint: .isDirectory)
        try? fm.copyItem(at: folder, to: copy)
        try? Data("garbage".utf8).write(to: copy.appending(path: "settings.json"))
        let copyJobs = store.jobs.count
        store.openFolder(copy)
        check("Damaged settings with no History show a problem screen (never setup)",
              store.launchProblem == .settingsDamaged(copy) && !store.needsOnboarding)
        await pause(1)
        snapshot("safety-settings-damaged")
        store.rebuildSettings(in: copy)
        check("Starting with default settings keeps every job", store.launchProblem == nil && store.jobs.count == copyJobs && store.settings.onboardingComplete)
        store.closeFolder()
        store.openFolder(folder)
        check("Back to the real folder", store.dataFolder == folder && store.jobs.count == copyJobs)

        // 5. A change made on another Mac shows up here.
        guard var fromOffice = store.job(jobB.id) else { return }
        fromOffice.name = "Hillcrest Apartments (office)"
        writeFromElsewhere(fromOffice, "\(b)/job.json")
        let pickedUp = await waitFor(4) { store.job(jobB.id)?.name == "Hillcrest Apartments (office)" }
        check("A change saved on another Mac appears here within seconds", pickedUp)
        check("…and is recorded in History", store.versions(of: "\(b)/job.json").contains { $0.reason == .external })

        // 6. Changed here and elsewhere at once: neither is lost.
        var mine = store.job(jobB.id)!
        mine.notes = "Gate code 4412 (edited on this Mac)"
        store.jobBinding(jobB.id).wrappedValue = mine
        var theirs = fromOffice
        theirs.address = "500 Hillcrest Ave (fixed on the office iMac)"
        writeFromElsewhere(theirs, "\(b)/job.json")
        let clash = await waitFor(4) { !store.conflicts.isEmpty }
        let onDisk = JSONFile.read(Job.self, from: path("\(b)/job.json"))
        check("Editing a file another Mac just changed asks which to keep, instead of overwriting",
              clash && onDisk?.address == theirs.address && onDisk?.notes != mine.notes)
        check("Both versions are in History before anything is chosen",
              store.versions(of: "\(b)/job.json").contains { $0.reason == .conflictMine })
        await pause(1)
        snapshotSheet("safety-two-versions")
        if let conflict = store.conflicts.first { store.resolve(conflict, keepMine: true) }
        await pause(0.5)
        check("Keep this Mac's version: saved", JSONFile.read(Job.self, from: path("\(b)/job.json"))?.notes == mine.notes && store.conflicts.isEmpty)

        var again = store.job(jobB.id)!
        again.notes = "Second edit here"
        store.jobBinding(jobB.id).wrappedValue = again
        var officeAgain = JSONFile.read(Job.self, from: path("\(b)/job.json"))!
        officeAgain.address = "18 Hillcrest Ct (second fix from the office)"
        writeFromElsewhere(officeAgain, "\(b)/job.json")
        let secondClash = await waitFor(4) { !store.conflicts.isEmpty }
        if let conflict = store.conflicts.first { store.resolve(conflict, keepMine: false) }
        await pause(0.3)
        let mineCount = store.versions(of: "\(b)/job.json").filter { $0.reason == .conflictMine }.count
        check("Keep the other Mac's version: loaded here, and this Mac's stays in History",
              secondClash && store.job(jobB.id)?.address == officeAgain.address && store.job(jobB.id)?.notes != "Second edit here" && mineCount >= 2
              && JSONFile.read(Job.self, from: path("\(b)/job.json"))?.address == officeAgain.address,
              "clash \(secondClash), notes \(store.job(jobB.id)?.notes ?? "-"), marked \(mineCount)")

        // 7. iCloud's "estimate 2.json" copies.
        var copyEstimate = store.estimates[jobA.id] ?? Estimate()
        copyEstimate.proposalNumber = "FROM-ICLOUD-COPY"
        writeFromElsewhere(copyEstimate, "\(a)/estimate 2.json")
        let copyFound = await waitFor(4) { store.conflicts.contains { if case .iCloudCopy = $0.source { return true }; return false } }
        check("An iCloud copy of a file is found and offered as a choice", copyFound)
        if let conflict = store.conflicts.first { store.resolve(conflict, keepMine: false) }
        await pause(0.5)
        check("Choosing the copy saves it in place and moves the extra copy out of the folder",
              JSONFile.read(Estimate.self, from: estimatePath)?.proposalNumber == "FROM-ICLOUD-COPY"
              && !fm.fileExists(atPath: path("\(a)/estimate 2.json").path))

        // 8. A job folder deleted on another Mac can be brought back.
        await pause(0.8)
        let bJob = json(store.job(jobB.id)), bTakeoff = json(store.takeoffs[jobB.id]), bEstimate = json(store.estimates[jobB.id])
        try? fm.removeItem(at: path(b))
        let gone = await waitFor(4) { store.job(jobB.id) == nil }
        store.checkHealth()
        check("A job deleted outside Stringline disappears here and is flagged in the health check",
              gone && (store.health?.issues.contains { $0.kind == .missingJob(folder: jobB.folderName) } ?? false))
        do { try store.restoreJob(folder: jobB.folderName) } catch { note("restoreJob: \(error.localizedDescription)") }
        check("Restore brings the whole job back from History",
              json(store.job(jobB.id)) == bJob && json(store.takeoffs[jobB.id]) == bTakeoff && json(store.estimates[jobB.id]) == bEstimate
              && fm.fileExists(atPath: path("\(b)/job.json").path))

        // 9. A second copy of a whole job folder is ignored, not loaded twice.
        let dupe = path("\(a) 2")
        try? fm.copyItem(at: path(a), to: dupe)
        reopen()
        check("A duplicated job folder isn't loaded twice", store.jobs.filter { $0.id == jobA.id }.count == 1 && store.duplicateFolders["\(jobA.folderName) 2"] == jobA.folderName)
        try? fm.removeItem(at: dupe)
        reopen()

        // 10. One Mac at a time.
        func officeLock(heartbeat: Date) {
            let info = LockInfo(machineID: "office-imac", machineName: "Office iMac", since: heartbeat, heartbeat: heartbeat)
            try? SafeFile.write(JSONFile.encode(info), to: path("in-use.json"))
        }
        officeLock(heartbeat: .now)
        let paused = await waitFor(4) { store.savingPaused != nil }
        check("When another Mac opens the folder, this Mac stops saving", paused && store.savingPaused?.machineName == "Office iMac")
        var pausedEdit = store.job(jobA.id)!
        pausedEdit.notes = "Edited while paused"
        store.jobBinding(jobA.id).wrappedValue = pausedEdit
        store.flush()
        await pause(0.8)
        check("…changes wait instead of being written", JSONFile.read(Job.self, from: path("\(a)/job.json"))?.notes != pausedEdit.notes && store.pendingCount > 0)
        await pause(0.5)
        snapshot("safety-saving-paused")
        store.takeOver()
        check("Use This Mac takes over and saves what was waiting",
              JSONFile.read(Job.self, from: path("\(a)/job.json"))?.notes == pausedEdit.notes && store.lock?.current()?.machineID == "selftest-this-mac")

        officeLock(heartbeat: .now)
        reopen()
        check("Opening a folder that's in use elsewhere asks first", store.showLockPrompt && store.savingPaused != nil)
        await pause(1.2)
        snapshotSheet("safety-in-use-elsewhere")
        try? fm.removeItem(at: path("in-use.json"))
        let resumed = await waitFor(4) { store.savingPaused == nil }
        check("When the other Mac closes Stringline, this Mac carries on saving by itself",
              resumed && store.notices.contains { $0.contains("isn't using Stringline anymore") })
        officeLock(heartbeat: Date().addingTimeInterval(-3600))
        reopen()
        check("A lock left by a Mac that crashed long ago doesn't get in the way", store.savingPaused == nil && !store.showLockPrompt)

        // 11. A save that fails is kept, shown, and retried.
        chmod(path(a).path, 0o555)
        var failing = store.job(jobA.id)!
        failing.notes = "Saved after the folder came back"
        store.jobBinding(jobA.id).wrappedValue = failing
        store.flush()
        let failedVisibly = store.problem?.hasPrefix("Couldn't save") == true && store.pendingCount > 0
            && store.versions(of: "\(a)/job.json").first?.reason == .unsaved
        check("A save that can't be written is reported, kept in History, and not lost", failedVisibly, store.problem ?? "no problem shown")
        await pause(0.3)
        snapshot("safety-save-failed")
        chmod(path(a).path, 0o755)
        let retried = await waitFor(8) { store.pendingCount == 0 }
        check("…and goes through by itself once the folder is writable again",
              retried && JSONFile.read(Job.self, from: path("\(a)/job.json"))?.notes == failing.notes && store.problem == nil)

        // 12. Restore an earlier version from History.
        let estimateFile = "\(a)/estimate.json"
        var versions: [Estimate] = []
        for n in 1...3 {
            var e = store.estimates[jobA.id] ?? Estimate()
            e.proposalNumber = "REV-\(n)"
            store.estimateBinding(jobA.id).wrappedValue = e
            store.flush()
            versions.append(e)
        }
        if let first = store.versions(of: estimateFile).first(where: { v in store.versionData(v).flatMap { JSONFile.decode(Estimate.self, from: $0) }?.proposalNumber == "REV-1" }) {
            try? store.restore(first)
        }
        check("Restoring an earlier version puts it back on disk and on screen",
              store.estimates[jobA.id]?.proposalNumber == "REV-1" && JSONFile.read(Estimate.self, from: estimatePath)?.proposalNumber == "REV-1")
        store.historyRequest = HistoryRequest(jobFolder: jobA.folderName, path: estimateFile)
        await pause(1.5)
        snapshotSheet("safety-history")
        store.historyRequest = nil
        await pause(0.6)

        // 13. Changes that couldn't be saved before quitting come back next time.
        officeLock(heartbeat: .now)
        _ = await waitFor(4) { store.savingPaused != nil }
        var lastWords = store.job(jobC.id)!
        lastWords.notes = "Typed right before quitting"
        store.jobBinding(jobC.id).wrappedValue = lastWords
        store.keepUnsavedInHistory()
        try? fm.removeItem(at: path("in-use.json"))
        store.closeFolder()
        store.openFolder(folder)
        store.checkHealth()
        let unsaved = store.unsavedLastTime.first { $0.path == "\(c)/job.json" }
        check("Unsaved changes from last time are offered back", unsaved != nil
              && (store.health?.issues.contains { if case .unsavedLastTime = $0.kind { return true }; return false } ?? false))
        if let unsaved { try? store.restore(unsaved) }
        check("…and restoring them saves them", JSONFile.read(Job.self, from: path("\(c)/job.json"))?.notes == lastWords.notes)

        // 14. Many quick edits in a row, with changes arriving from elsewhere in between: nothing lost.
        var rng = SystemRandomNumberGenerator()
        let ids = store.realJobs.map(\.id)
        for step in 0..<400 {
            let id = ids[Int.random(in: 0..<ids.count, using: &rng)]
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                var j = store.job(id)!; j.notes = "note \(step)"; store.jobBinding(id).wrappedValue = j
            case 1:
                var t = store.takeoffs[id] ?? Takeoff(); t.spanMeters = Double(100 + step); store.takeoffBinding(id).wrappedValue = t
            case 2:
                var l = store.logs[id] ?? JobLogs(); l.entries.append(DailyLog(day: Date().startOfDay, crewID: nil, tons: Double(step), hours: 8, weather: "", notes: "")); store.logsBinding(id).wrappedValue = l
            case 3:
                store.settings.nextProposalNumber += 1; store.markDirty(.settings)
            default:
                var r = store.rates; r.factors.wastePct = Double(step % 10); store.ratesBinding.wrappedValue = r
            }
            if step % 7 == 0 { store.flush() }
            if step % 50 == 0 { store.rescan() }
            if step % 25 == 0 { await pause(0.05) }
        }
        store.flush()
        await pause(1.5)
        let check2 = makeStore()
        check2.openFolder(folder)
        let same = store.jobs.allSatisfy { j in
            json(check2.job(j.id)) == json(j) && json(check2.takeoffs[j.id]) == json(store.takeoffs[j.id]) && json(check2.logs[j.id]) == json(store.logs[j.id])
        } && json(check2.settings) == json(store.settings) && json(check2.rates) == json(store.rates)
        check("400 quick edits: every one is on disk exactly as on screen", same && store.conflicts.isEmpty && store.pendingCount == 0,
              "conflicts \(store.conflicts.count), waiting \(store.pendingCount)")
        check2.closeFolder(releaseLock: false)

        // 15. Backups land on this Mac too.
        store.runBackupIfDue(force: true)
        let local = store.localBackupsFolder(for: folder)
        let backedUp = await waitFor(6) {
            ((try? fm.contentsOfDirectory(atPath: local.path)) ?? []).contains { $0.hasSuffix(".zip") }
                && ((try? fm.contentsOfDirectory(atPath: path("backups").path)) ?? []).contains { $0.hasSuffix(".zip") }
        }
        check("Backups are kept on this Mac and in the PavingData folder", backedUp)

        // 16. A clean bill of health.
        await pause(1)
        store.checkHealth(deep: true)
        let issues = store.health?.issues ?? []
        check("Health check: every file opens and nothing needs attention", issues.isEmpty && (store.health?.files ?? 0) > 10,
              issues.isEmpty ? "\(store.health?.files ?? 0) files" : issues.map(\.title).joined(separator: " | "))
        store.settingsSectionRequest = .data
        store.selection = .settings
        await pause(1.5)
        snapshot("safety-data-settings")
        let journalSize = (try? fm.attributesOfItem(atPath: store.historyURL(for: folder).path)[.size] as? Int) ?? 0
        note("History: \(store.journal?.count ?? 0) versions, \(ByteCountFormatter.string(fromByteCount: Int64(journalSize), countStyle: .file)) on disk")
        FolderLock.interval = 60
        FolderLock.staleAfter = 300
    }
}
#endif
