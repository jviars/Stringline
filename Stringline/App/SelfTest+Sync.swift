#if DEBUG
import AppKit

/// iCloud's sync service can stop answering (it crashes, or gets stuck after the account ran out of space).
/// Anything waiting on it through file coordination would wait forever, which once froze setup.
/// These checks hold files the way a stuck iCloud does and make sure the app never freezes.
extension SelfTest {
    static var fakeICloud: URL { outputFolder.appending(path: "iCloud Drive", directoryHint: .isDirectory) }

    /// Holds file coordination on two files until `end()`, the way a stuck iCloud does.
    final class Hold {
        private let release = DispatchSemaphore(value: 0)
        private let done = DispatchSemaphore(value: 0)

        init(_ first: URL, _ second: URL) {
            let holding = DispatchSemaphore(value: 0)
            let release = release, done = done
            Thread.detachNewThread {
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: first, options: [], writingItemAt: second, options: [], error: &error) { _, _ in
                    holding.signal()
                    release.wait()
                }
                done.signal()
            }
            holding.wait()
        }

        func end() {
            release.signal()
            done.wait()
        }
    }

    /// The longest the main thread went without running while `seconds` passed. A frozen app shows up as a long lag.
    static func worstLag(over seconds: Double) async -> Double {
        var worst = 0.0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let start = Date()
            await pause(0.1)
            worst = max(worst, Date().timeIntervalSince(start) - 0.1)
        }
        return worst
    }

    private static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var found = (view as? NSTextField).map { [$0.stringValue] } ?? (view as? NSButton).map { [$0.title] } ?? []
        for sub in view.subviews { found += texts(in: sub) }
        return found
    }

    static func snapshotSheet(_ sheet: NSWindow, _ name: String) {
        guard let view = sheet.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        shot += 1
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = outputFolder.appending(path: "screens", directoryHint: .isDirectory)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: String(format: "%02d-%@.png", shot, name)))
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { await pause(0.1) }
        return condition()
    }

    // MARK: - Setup

    /// Setup's iCloud Drive choice while iCloud isn't answering: no freeze, a clear message, and it carries on once iCloud is back.
    static func runStuckICloudSetup(store: AppStore) async {
        lines.append("")
        lines.append("-- Setup while iCloud Drive isn't answering")
        let fm = FileManager.default
        let saved = (SafeFile.coordinationTimeout, SafeFile.recheckInterval)
        SafeFile.coordinationTimeout = 1.5
        SafeFile.recheckInterval = 0.5
        defer { (SafeFile.coordinationTimeout, SafeFile.recheckInterval) = saved }
        try? fm.removeItem(at: fakeICloud.appending(path: "Stringline"))
        guard let target = AppStore.suggestedICloudFolder, let window else {
            check("Setup offers the stand-in iCloud Drive", false)
            return
        }
        // The folder doesn't exist yet, so the check asks iCloud Drive itself: hold that, and the file setup would write.
        let hold = Hold(fakeICloud.appending(path: ".stringline-check"), target.appending(path: "settings.json"))

        store.onboardingStepRequest = 2
        let lagWhileChecking = await worstLag(over: SafeFile.coordinationTimeout + 0.8)
        snapshot("setup-icloud-not-responding")
        check("Opening the folder step checks iCloud in the background without freezing", lagWhileChecking < 0.5, String(format: "worst lag %.2fs", lagWhileChecking))

        key("\r", 36, in: window)
        let lagOnContinue = await worstLag(over: SafeFile.coordinationTimeout + 0.8)
        let alert = await waitUntil(3) { window.attachedSheet != nil }
        check("Continue with iCloud Drive stuck doesn't freeze the app", lagOnContinue < 0.5, String(format: "worst lag %.2fs", lagOnContinue))
        if let sheet = window.attachedSheet {
            snapshotSheet(sheet, "setup-icloud-alert")
            let words = texts(in: sheet.contentView).joined(separator: " ")
            check("…and explains that iCloud Drive isn't responding, with a way forward",
                  words.contains("iCloud Drive isn't responding") && words.contains("Use a Folder on This Mac"), words)
            key("\u{1b}", 53, in: sheet)
        } else {
            check("…and explains that iCloud Drive isn't responding, with a way forward", alert)
        }
        let closed = await waitUntil(3) { window.attachedSheet == nil }
        check("Cancel leaves setup where it was, with nothing written to iCloud",
              closed && store.dataFolder == nil && !fm.fileExists(atPath: target.appending(path: "settings.json").path))

        hold.end()
        let recovered = await waitUntil(5) { !SafeFile.isNotResponding(target) }
        key("\r", 36, in: window)
        let created = await waitUntil(8) { store.dataFolder?.standardizedFileURL.path == target.standardizedFileURL.path }
        check("Once iCloud answers again, Continue sets up the folder there",
              recovered && created && fm.fileExists(atPath: target.appending(path: "settings.json").path),
              "recovered \(recovered), folder \(store.dataFolder?.path ?? "none")")

        // Back to a fresh start for the rest of the test.
        store.closeFolder()
        store.forgetFolder()
        await pause(0.5)
    }

    // MARK: - Saving and opening

    /// Saving, and opening the folder, while its sync service isn't answering.
    static func runStuckSync(store: AppStore, folder: URL) async {
        lines.append("")
        lines.append("-- Saving while iCloud isn't answering")
        let saved = (SafeFile.coordinationTimeout, SafeFile.recheckInterval, SafeFile.testSyncFolders)
        SafeFile.coordinationTimeout = 1.5
        SafeFile.recheckInterval = 0.5
        SafeFile.testSyncFolders.append(folder.standardizedFileURL.path)
        defer { (SafeFile.coordinationTimeout, SafeFile.recheckInterval, SafeFile.testSyncFolders) = saved }
        store.flush()
        let settingsURL = folder.appending(path: "settings.json")
        let before = try? Data(contentsOf: settingsURL)

        var hold = Hold(settingsURL, folder.appending(path: ".stringline-check"))
        store.settings.company.phone = "555-0199"
        store.markDirty(.settings)
        _ = await waitUntil(5) { store.problem == AppStore.syncStuckProblem }
        check("A save while iCloud isn't answering gives up and says so", store.problem == AppStore.syncStuckProblem, store.problem ?? "no message")
        check("…without touching the file", (try? Data(contentsOf: settingsURL)) == before)
        check("…and the change is kept on this Mac", store.pendingCount > 0
              && (store.journal?.latestVersions().contains { $0.path == "settings.json" && $0.reason == .unsaved } ?? false))
        snapshot("sync-stuck-banner")

        store.settings.company.phone = "555-0198"
        store.markDirty(.settings)
        let lagWhileStuck = await worstLag(over: 3)
        check("While it's stuck, more edits and retries don't freeze the app", lagWhileStuck < 0.5, String(format: "worst lag %.2fs", lagWhileStuck))

        hold.end()
        let savedLater = await waitUntil(10) {
            (try? Data(contentsOf: settingsURL)).flatMap { JSONFile.decode(AppSettings.self, from: $0) }?.company.phone == "555-0198"
        }
        check("When iCloud answers again, the waiting change saves by itself", savedLater && store.pendingCount == 0 && store.problem == nil,
              "saved \(savedLater), waiting \(store.pendingCount), message \(store.problem ?? "none")")

        // Opening the folder while it's stuck shows the waiting screen, then opens by itself.
        store.closeFolder()
        hold = Hold(settingsURL, folder.appending(path: ".stringline-check"))
        let start = Date()
        store.openFolder(folder)
        let openTime = Date().timeIntervalSince(start)
        check("Opening the folder while iCloud is stuck shows the waiting screen instead of hanging",
              store.launchProblem == .syncNotResponding(folder) && openTime < SafeFile.coordinationTimeout + 1,
              String(format: "%@ after %.1fs", String(describing: store.launchProblem), openTime))
        await pause(0.8)
        snapshot("sync-stuck-launch")
        let lagOnProblemScreen = await worstLag(over: 4)
        check("…and its automatic retries don't freeze the app", lagOnProblemScreen < 0.5, String(format: "worst lag %.2fs", lagOnProblemScreen))
        hold.end()
        let reopened = await waitUntil(12) { store.dataFolder != nil && store.launchProblem == nil }
        check("…then opens by itself once iCloud answers", reopened && store.settings.company.phone == "555-0198")
        await pause(0.5)
    }

    // MARK: - Import from Zoho

    /// File › Import from Zoho… with real files and a real zip: the preview, one Import, no duplicates the second time, and ⌘Z.
    static func runZohoImport(store: AppStore) async {
        lines.append("")
        lines.append("-- Import from Zoho")
        let fm = FileManager.default
        let folder = outputFolder.appending(path: "zoho", directoryHint: .isDirectory)
        let zipped = folder.appending(path: "export", directoryHint: .isDirectory)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: zipped, withIntermediateDirectories: true)
        let accounts = folder.appending(path: "Accounts_001.csv"), contacts = folder.appending(path: "Contacts_001.csv")
        try? Data("""
        "Record Id","Account Name","Phone","Account Type","Billing Street","Billing City","Billing State","Billing Code","Description"
        "4876876000000111","Ridge Property Group","(614) 555-0100","Customer","100 Ridge Rd","Columbus","OH","43215","Manages 12 lots"
        "4876876000000112","Cedar Lane HOA","614-555-0200","Homeowners Association","1 Cedar Ln","Dublin","OH","43017",""
        """.utf8).write(to: accounts)
        try? Data("""
        "Record Id","First Name","Last Name","Account Name","Account Name.id","Email","Mobile","Mailing Street","Mailing City","Mailing State","Mailing Zip"
        "4876876000000212","Sam","Lee","Ridge Property Group","4876876000000111","sam@ridgepg.com","614-555-0102","","","",""
        "4876876000000213","Jo","Homeowner","","","jo@example.com","614-555-0300","22 Elm St","Columbus","OH","43210"
        """.utf8).write(to: contacts)
        try? Data("""
        "Record Id","Deal Name","Account Name","Account Name.id","Contact Name","Stage","Closing Date","Amount"
        "4876876000000311","Ridge back lot overlay","Ridge Property Group","4876876000000111","","Proposal/Price Quote","2026-11-15","42,000"
        "4876876000000312","Cedar Lane sealcoat","Cedar Lane HOA","4876876000000112","","Closed Won","10/01/2026","$12,400.00"
        "4876876000000314","Elm St driveway","","","Jo Homeowner","Qualification","",""
        """.utf8).write(to: zipped.appending(path: "Deals_001.csv"))
        try? Data("""
        "Note Id","Note Title","Note Content","Parent ID"
        "1","Call","Wants it done before Thanksgiving","4876876000000311"
        """.utf8).write(to: zipped.appending(path: "Notes_001.csv"))
        let zip = folder.appending(path: "Zoho_Export.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", zipped.path, zip.path]
        try? ditto.run()
        ditto.waitUntilExit()

        let session = ZohoImporter.load([accounts, contacts, zip])
        check("Zoho's CSV files and the zip it downloads are read and recognized",
              Set(session.tables.map(\.kind)) == [.accounts, .contacts, .deals, .notes] && session.problems.isEmpty,
              session.tables.map { "\($0.fileName): \($0.kind)" }.joined(separator: ", "))
        store.selection = .customers
        await pause(1)
        snapshot("customers-import-button")
        store.zohoImport = session
        await pause(1.5)
        if let sheet = window?.attachedSheet { snapshotSheet(sheet, "zoho-import-preview") }
        check("Import from Zoho opens its preview window", window?.attachedSheet != nil)

        let customersBefore = store.customers.count, jobsBefore = store.jobs.count
        let plan = ZohoImport.plan(session.tables, customers: store.customers, jobs: store.jobs)
        // Press Return: the window's own Import button.
        if let sheet = window?.attachedSheet { key("\r", 36, in: sheet) }
        _ = await waitUntil(5) { store.jobs.count > jobsBefore }
        await pause(0.8)
        if let sheet = window?.attachedSheet { snapshotSheet(sheet, "zoho-import-done") }
        let words = window?.attachedSheet.map { texts(in: $0.contentView).joined(separator: " ") } ?? ""
        store.zohoImport = nil
        await pause(0.8)
        store.flush()
        let done = (customers: store.customers.count - customersBefore, jobs: store.jobs.count - jobsBefore)
        check("Pressing Import adds what the preview promised", done.customers == plan.newCustomers.count && done.jobs == plan.newJobs.count,
              "\(done) vs \(plan.newCustomers.count) customers, \(plan.newJobs.count) jobs \(words)")
        let cedar = store.customers.first { $0.name == "Cedar Lane HOA" }
        let sealJob = store.jobs.first { $0.name == "Cedar Lane sealcoat" }
        let jobFile = sealJob.flatMap { store.jobFolder($0) }.map { $0.appending(path: "job.json") }
        check("Import adds the customers and jobs, saved to the PavingData folder",
              done.customers >= 2 && done.jobs == 3 && store.customers.count == customersBefore + done.customers && store.jobs.count == jobsBefore + 3
                && jobFile.map { fm.fileExists(atPath: $0.path) } == true && cedar.flatMap { store.dataFolder?.appending(path: "customers/\($0.id.uuidString).json") }.map { fm.fileExists(atPath: $0.path) } == true,
              "\(done.customers) customers, \(done.jobs) jobs")
        check("Deals land at the right stage, for the right customer, with their notes",
              sealJob?.stage == .won && sealJob?.customerID == cedar?.id
                && store.jobs.first { $0.name == "Ridge back lot overlay" }.map { $0.stage == .sent && $0.notes.contains("Thanksgiving") } == true)
        check("A customer you already had is matched, not duplicated",
              store.customers.filter { $0.name == "Ridge Property Group" }.count == 1)
        check("Importing the same files again would add nothing",
              ZohoImport.plan(session.tables, customers: store.customers, jobs: store.jobs).isEmpty)
        await pause(0.8)
        snapshot("customers-after-zoho-import")
        window?.undoManager?.undo()
        await pause(0.5)
        store.flush()
        check("⌘Z undoes the whole import", store.customers.count == customersBefore && store.jobs.count == jobsBefore
              && !store.jobs.contains { $0.name == "Cedar Lane sealcoat" })
    }

    // MARK: - A real map picture

    /// Asks Apple Maps for a real picture of a lot, as look_at_map does, and saves it (STRINGLINE_TEST_ONLY=mappicture).
    static func saveMapPicture() async {
        let frame = MapFrame(center: Coordinate(lat: 40.1453, lon: -82.9818), spanMeters: 300)
        var shape = TakeoffShape()
        shape.name = "Test area"
        shape.points = [frame.coordinate(gridX: 300, gridY: 300), frame.coordinate(gridX: 700, gridY: 300),
                        frame.coordinate(gridX: 700, gridY: 600), frame.coordinate(gridX: 300, gridY: 600)]
        do {
            let url = try await AppleServices().mapPicture(frame, shapes: [shape])
            let data = Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))) ?? Data()
            try? data.write(to: outputFolder.appending(path: "map-picture.jpg"))
            check("Apple Maps makes a gridded satellite picture for look_at_map", data.count > 40_000, "\(data.count) bytes")
        } catch {
            check("Apple Maps makes a gridded satellite picture for look_at_map", false, error.localizedDescription)
        }
    }

    // MARK: - Quick run

    /// Just the Zoho import checks (STRINGLINE_TEST_ONLY=zoho), on a fresh folder with one customer.
    static func runZohoOnly(store: AppStore, folder: URL, then other: (() async -> Void)? = nil) async {
        NSApp.activate(ignoringOtherApps: true)
        await pause(1.5)
        window?.setContentSize(NSSize(width: 1440, height: 920))
        window?.makeKeyAndOrderFront(nil)
        store.settings.company.name = "Test Paving Co"
        try? store.createDataFolder(at: folder)
        store.settings.onboardingComplete = true
        store.markDirty(.settings)
        var ridge = store.createCustomer(name: "Ridge Property Group")
        ridge.contact = "Dana Whitfield"
        store.customerBinding(ridge.id).wrappedValue = ridge
        store.flush()
        await pause(1)
        if let other { await other() } else { await runZohoImport(store: store) }
        finish(store)
    }

    /// Just these checks (STRINGLINE_TEST_ONLY=sync), on a fresh folder.
    static func runSyncOnly(store: AppStore, folder: URL) async {
        NSApp.activate(ignoringOtherApps: true)
        await pause(1.5)
        window?.setContentSize(NSSize(width: 1440, height: 920))
        window?.makeKeyAndOrderFront(nil)
        await pause(1)
        await runStuckICloudSetup(store: store)
        store.settings.company.name = "Test Paving Co"
        try? store.createDataFolder(at: folder)
        store.settings.onboardingComplete = true
        store.markDirty(.settings)
        store.flush()
        await pause(1)
        await runStuckSync(store: store, folder: folder)
        finish(store)
    }
}
#endif
