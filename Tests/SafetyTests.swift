import Foundation

/// A file whose contents prove whether it was written whole: every item equals `version`,
/// and there are exactly `expectedCount(version)` of them.
struct Payload: Codable, Equatable, DefaultInit {
    var version = 0
    var items: [Int] = []
    var note = ""

    static func expectedCount(_ version: Int) -> Int { 400 + (version % 7) * 350 }

    static func make(_ version: Int) -> Payload {
        Payload(version: version, items: Array(repeating: version, count: expectedCount(version)),
                note: String(repeating: "asphalt ", count: version % 300))
    }

    var isWhole: Bool { items.count == Payload.expectedCount(version) && items.allSatisfy { $0 == version } }
}

/// Child-process mode: write versions of payload.json (and record them in History) forever, until killed.
func runWriter(folder: URL, start: Int) -> Never {
    let file = folder.appendingPathComponent("payload.json")
    let journal = Journal(url: folder.appendingPathComponent("history.sqlite"), folderPath: folder.path)
    var version = start
    while true {
        let data = try! JSONFile.encode(Payload.make(version))
        let entry = journal.record("payload.json", data, reason: .unsaved, label: "Payload")
        try? SafeFile.write(data, to: file)
        if let entry { journal.mark(entry, as: .saved) }
        version += 1
    }
}

func runSafetyTests(_ base: URL) {
    let fm = FileManager.default
    func fresh(_ name: String) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: url)
        try! fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Safe writes
    let dir = fresh("safe")
    let file = dir.appendingPathComponent("job.json")
    var job = Job(); job.name = "Maple Ridge Plaza"; job.number = "2026-001"
    try! JSONFile.write(job, to: file)
    check("Safe write then read gives the same job", JSONFile.read(Job.self, from: file).map { try! JSONFile.encode($0) } == (try! JSONFile.encode(job)))
    let firstInode = SafeFile.stamp(file)?.inode
    job.name = "Maple Ridge Plaza (phase 2)"
    try! JSONFile.write(job, to: file)
    check("A save replaces the file in one step (new file swapped in)", SafeFile.stamp(file)?.inode != firstInode)
    let leftovers = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    check("Saving leaves no temporary files in the folder", leftovers == ["job.json"], "\(leftovers)")
    if case .missing = SafeFile.read(dir.appendingPathComponent("nope.json")) { check("A file that isn't there reads as missing", true) } else { check("A file that isn't there reads as missing", false) }

    try! Data().write(to: dir.appendingPathComponent(".takeoff.json.icloud"))
    if case .notDownloaded = SafeFile.read(dir.appendingPathComponent("takeoff.json")) {
        check("An iCloud placeholder reads as not downloaded (never as missing)", true)
    } else { check("An iCloud placeholder reads as not downloaded (never as missing)", false) }
    check("A placeholder still counts as an existing file", SafeFile.exists(dir.appendingPathComponent("takeoff.json")))
    SafeFile.simulatedNotDownloaded = [file.standardizedFileURL.path]
    if case .notDownloaded = JSONFile.load(Job.self, from: file) { check("An evicted (not downloaded) file isn't read or waited on", true) } else { check("An evicted (not downloaded) file isn't read or waited on", false) }
    SafeFile.simulatedNotDownloaded = []

    let locked = dir.appendingPathComponent("locked.json")
    try! JSONFile.write(job, to: locked)
    chmod(locked.path, 0o000)
    if case .unreadable = SafeFile.read(locked) { check("A file macOS won't let us read is reported, not treated as empty", true) } else { check("A file macOS won't let us read is reported, not treated as empty", geteuid() == 0) }
    chmod(locked.path, 0o644)

    let readOnly = fresh("readonly")
    let keep = readOnly.appendingPathComponent("estimate.json")
    var estimate = Estimate(); estimate.proposalNumber = "2026-014"
    try! JSONFile.write(estimate, to: keep)
    chmod(readOnly.path, 0o555)
    var failedAsExpected = false
    var changed = estimate; changed.proposalNumber = "CHANGED"
    do { try JSONFile.write(changed, to: keep) } catch { failedAsExpected = true }
    chmod(readOnly.path, 0o755)
    check("When a save can't happen, it fails loudly and the old file is untouched",
          failedAsExpected && JSONFile.read(Estimate.self, from: keep)?.proposalNumber == "2026-014")

    // MARK: Garbled files never load as something they aren't
    var sample = Job(); sample.name = "Riverbend Elementary"; sample.address = "12 School Rd"; sample.services = [.millOverlay, .striping]
    sample.schedule = [ScheduleEntry(day: Date().startOfDay, crewID: nil, startTime: "7:00 AM", note: "Mill")]
    let good = try! JSONFile.encode(sample)
    var truncationsOK = true
    for length in 0..<good.count {
        switch JSONFile.interpret(Job.self, good.prefix(length)) {
        case .damaged: continue
        case .ok(let value, _, _): if value != sample { truncationsOK = false }
        default: truncationsOK = false
        }
    }
    check("A file cut off at any of its \(good.count) bytes is caught as damaged", truncationsOK)
    var rng = SystemRandomNumberGenerator()
    var garbledCrashFree = true
    for _ in 0..<2000 {
        var bytes = [UInt8](good)
        for _ in 0..<Int.random(in: 1...8, using: &rng) {
            bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
        }
        switch JSONFile.interpret(Job.self, Data(bytes)) {
        case .damaged, .ok, .newer: break
        default: garbledCrashFree = false
        }
    }
    check("2,000 randomly scrambled files are handled without a crash", garbledCrashFree)
    let oddFiles: [String: Data] = ["empty": Data(), "zeros": Data(count: 4096), "array": Data("[]".utf8), "null": Data("null".utf8),
                                    "number": Data("42".utf8), "binary": Data((0..<512).map { _ in UInt8.random(in: 0...255) }),
                                    "html": Data("<html>502 Bad Gateway</html>".utf8), "wrong type": Data(#"{"name": 5}"#.utf8)]
    let badOnes = oddFiles.filter { _, data in if case .damaged = JSONFile.interpret(Job.self, data) { return false } else { return true } }
    check("Empty, zero-filled, binary and wrong-shaped files are all caught as damaged", badOnes.isEmpty, "\(badOnes.keys)")
    if case .newer = JSONFile.interpret(Job.self, Data(#"{"schemaVersion": 2, "name": "Future"}"#.utf8)) {
        check("A file from a newer Stringline is recognized (and left alone)", true)
    } else { check("A file from a newer Stringline is recognized (and left alone)", false) }

    // MARK: Fields from a newer version survive a save
    let future = Data(#"{"schemaVersion":1,"name":"Lot","futureField":{"a":1},"company":{"name":"X"},"stage":"lead"}"#.utf8)
    if case .ok(var loaded, _, let extras) = JSONFile.interpret(Job.self, future) {
        loaded.name = "Lot B"
        let saved = try! JSONFile.encode(loaded, preserving: extras)
        let object = (try? JSONSerialization.jsonObject(with: saved)) as? [String: Any] ?? [:]
        check("Unknown fields from a newer version are kept when saving", (object["futureField"] as? [String: Any])?["a"] as? Int == 1
              && JSONFile.decode(Job.self, from: saved)?.name == "Lot B")
    } else { check("Unknown fields from a newer version are kept when saving", false) }
    var withDate = AppSettings(); withDate.lastBackup = Date()
    let settingsData = try! JSONFile.encode(withDate)
    if case .ok(var s2, _, let extras) = JSONFile.interpret(AppSettings.self, settingsData) {
        s2.lastBackup = nil
        let saved = try! JSONFile.encode(s2, preserving: extras)
        check("Clearing a field stays cleared (not brought back by the extras)", JSONFile.decode(AppSettings.self, from: saved)?.lastBackup == nil)
    } else { check("Clearing a field stays cleared (not brought back by the extras)", false) }

    // MARK: File names
    let id = UUID()
    check("Paths map to data files and back", DataFile(path: "jobs/2026-001-plaza/estimate.json") == .job(folder: "2026-001-plaza", part: .estimate)
          && DataFile(path: "customers/\(id.uuidString).json") == .customer(id) && DataFile(path: "settings.json")?.path == "settings.json"
          && DataFile(path: "jobs/2026-001-plaza/notes.json") == nil && DataFile(path: "backups/x.json") == nil)
    check("iCloud's clashing copies are recognized", DataFile.conflictOriginal(of: "jobs/x/estimate 2.json") == "jobs/x/estimate.json"
          && DataFile.conflictOriginal(of: "customers/\(id.uuidString) 3.json") == "customers/\(id.uuidString).json"
          && DataFile.conflictOriginal(of: "in-use 2.json") == "in-use.json"
          && DataFile.conflictOriginal(of: "settings.json") == nil && DataFile.conflictOriginal(of: "notes 2.json") == nil)
    let tree = fresh("tree")
    for path in ["settings.json", "rates.json", "customers/\(id.uuidString).json", "jobs/a/job.json", "jobs/a/estimate.json",
                 "jobs/a/estimate 2.json", "jobs/a/.takeoff.json.icloud", "in-use.json", "in-use 2.json", "backups/old.json"] {
        let url = tree.appendingPathComponent(path)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("{}".utf8).write(to: url)
    }
    let listing = DataFile.list(tree)
    check("Folder listing finds data files, iCloud copies and files still downloading",
          listing.files == ["settings.json", "rates.json", "customers/\(id.uuidString).json", "jobs/a/job.json", "jobs/a/estimate.json"]
          && listing.copies == ["jobs/a/estimate.json": ["jobs/a/estimate 2.json"]] && listing.placeholders == ["jobs/a/takeoff.json"]
          && listing.lockCopies == ["in-use 2.json"], "\(listing.files) \(listing.copies) \(listing.placeholders)")

    // MARK: History (SQLite on this Mac)
    let historyDir = fresh("history")
    let historyURL = historyDir.appendingPathComponent("h.sqlite")
    var journal: Journal? = Journal(url: historyURL, folderPath: "/test")
    let v1 = try! JSONFile.encode(sample)
    var sample2 = sample; sample2.name = "Riverbend Elementary (rev)"
    let v2 = try! JSONFile.encode(sample2)
    let first = journal!.record("jobs/a/job.json", v1, reason: .saved, label: "Riverbend")
    let duplicate = journal!.record("jobs/a/job.json", v1, reason: .loaded, label: "Riverbend")
    journal!.record("jobs/a/job.json", v2, reason: .saved, label: "Riverbend")
    let marker = journal!.record("jobs/a/job.json", v2, reason: .conflictMine, label: "Riverbend")
    check("History keeps each new version once, and always keeps marked ones", first != nil && duplicate == nil && marker != nil
          && journal!.versions(of: "jobs/a/job.json").count == 3)
    check("A version comes back byte for byte", journal!.data(first!) == v1)
    journal!.record("jobs/a/job.json", Data("{ broken".utf8), reason: .external, label: "Riverbend")
    let goodOne = journal!.latestGood("jobs/a/job.json") { JSONFile.decode(Job.self, from: $0) != nil }
    check("History finds the newest version that still reads correctly", goodOne?.1 == v2)
    let pendingEntry = journal!.record("jobs/b/job.json", v1, reason: .unsaved, label: "B")
    journal!.record("jobs/b/job.json", v1, reason: .loaded, label: "B")
    check("A save found on disk at next launch is marked saved", pendingEntry != nil && journal!.versions(of: "jobs/b/job.json").first?.reason == .saved)
    journal = nil
    let reopened = Journal(url: historyURL, folderPath: "/test")
    check("History survives closing and reopening", reopened.versions(of: "jobs/a/job.json").count == 4 && reopened.problem == nil)
    reopened.close()
    try! Data(repeating: 0x41, count: 8192).write(to: historyURL)
    try? fm.removeItem(at: URL(fileURLWithPath: historyURL.path + "-wal"))
    try? fm.removeItem(at: URL(fileURLWithPath: historyURL.path + "-shm"))
    let rebuilt = Journal(url: historyURL, folderPath: "/test")
    let asideFiles = ((try? fm.contentsOfDirectory(atPath: historyDir.path)) ?? []).filter { $0.hasPrefix("damaged-") }
    check("A damaged history is set aside and a fresh one starts", rebuilt.problem != nil && !asideFiles.isEmpty
          && rebuilt.record("x.json", v1, reason: .saved, label: "x") != nil, "\(asideFiles)")
    rebuilt.close()

    let now = Date()
    let day: TimeInterval = 86_400
    var rows: [(id: Int64, path: String, savedAt: Date, reason: Journal.Reason)] = []
    var nextID: Int64 = 1
    func add(_ age: TimeInterval, _ reason: Journal.Reason = .saved, path: String = "f.json") {
        rows.append((nextID, path, now.addingTimeInterval(-age), reason)); nextID += 1
    }
    for minute in 0..<120 { add(Double(minute) * 60) }                       // 2 hours of saves today
    // Line the old saves up inside one clock hour and one calendar day, like real saves would be.
    let hourStart = (now.timeIntervalSince1970 - 20 * day).rounded(.down) - (now.timeIntervalSince1970 - 20 * day).truncatingRemainder(dividingBy: 3600)
    for minute in 0..<30 { add(now.timeIntervalSince1970 - (hourStart + 60 + Double(minute) * 60)) }   // 30 saves in one hour, 20 days ago
    let dayStart = (now.timeIntervalSince1970 - 200 * day) - (now.timeIntervalSince1970 - 200 * day).truncatingRemainder(dividingBy: day)
    for hour in 0..<5 { add(now.timeIntervalSince1970 - (dayStart + 3600 + Double(hour) * 3600)) }    // 5 saves in one day, 200 days ago
    add(800 * day)                                                           // older than two years
    add(40 * day + 30, .conflictMine)                                        // a marked version, 40 days ago
    add(1000 * day, path: "only.json")                                       // the only version of another file
    let thinned = Set(Journal.idsToThin(rows, now: now))
    let kept = rows.filter { !thinned.contains($0.id) }
    check("History thinning keeps every recent save", kept.filter { now.timeIntervalSince($0.savedAt) < 14 * day }.count == 120)
    check("History thinning keeps one an hour after two weeks, one a day after 90 days",
          kept.filter { (19 * day..<21 * day).contains(now.timeIntervalSince($0.savedAt)) }.count == 1
          && kept.filter { (199 * day..<201 * day).contains(now.timeIntervalSince($0.savedAt)) }.count == 1)
    check("History thinning drops versions over two years old but never a file's only copy, or a marked one",
          !kept.contains { now.timeIntervalSince($0.savedAt) > 799 * day && $0.path == "f.json" }
          && kept.contains { $0.path == "only.json" } && kept.contains { $0.reason == .conflictMine })

    // MARK: One Mac at a time
    let lockDir = fresh("lock")
    let office = FolderLock(folder: lockDir, machineID: "office", machineName: "Office iMac")
    let laptop = FolderLock(folder: lockDir, machineID: "laptop", machineName: "MacBook")
    try! office.claim()
    check("The laptop sees the office iMac has the folder open", laptop.otherOwner()?.machineName == "Office iMac" && office.otherOwner() == nil)
    try! laptop.claim()
    check("After the laptop takes over, the office iMac's next heartbeat notices and backs off",
          (try? office.beat())??.machineName == "MacBook" && laptop.current()?.machineID == "laptop")
    var stale = laptop.current()!; stale.heartbeat = Date().addingTimeInterval(-3600)
    try! SafeFile.write(JSONFile.encode(stale), to: laptop.url)
    check("A lock left by a Mac that crashed an hour ago is ignored", office.otherOwner() == nil)
    office.release()
    check("A Mac only releases its own lock", SafeFile.exists(laptop.url))
    laptop.release()
    check("Releasing removes the lock", !SafeFile.exists(laptop.url))
}

/// Holds file coordination on some files until released, the way a stuck iCloud sync service does.
final class CoordinationHold {
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

/// iCloud's sync service can stop answering (it crashes, or gets stuck after the account ran out of space).
/// File coordination then waits forever, which froze setup. Every coordinated read and write must give up in time.
func runSyncStallTests(_ base: URL) {
    print("\n-- When iCloud stops answering")
    let fm = FileManager.default
    let folder = base.appendingPathComponent("stalled-sync", isDirectory: true)
    try? fm.removeItem(at: folder)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let saved = (SafeFile.coordinationTimeout, SafeFile.recheckInterval)
    SafeFile.coordinationTimeout = 0.6
    SafeFile.recheckInterval = 0.2
    SafeFile.testSyncFolders = [folder.standardizedFileURL.path]
    defer {
        (SafeFile.coordinationTimeout, SafeFile.recheckInterval) = saved
        SafeFile.testSyncFolders = []
    }

    check("iCloud Drive and other sync folders are recognized, ordinary folders aren't",
          SafeFile.syncRoot(of: URL(fileURLWithPath: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Stringline/PavingData/settings.json")) == "/Users/a/Library/Mobile Documents"
          && SafeFile.syncRoot(of: URL(fileURLWithPath: "/Users/a/Library/CloudStorage/Dropbox/PavingData/settings.json")) == "/Users/a/Library/CloudStorage/Dropbox"
          && SafeFile.syncRoot(of: URL(fileURLWithPath: "/Users/a/Documents/PavingData/settings.json")) == nil)

    let settings = folder.appendingPathComponent("settings.json")
    let rates = folder.appendingPathComponent("rates.json")
    try! SafeFile.write(Data("old".utf8), to: settings)
    check("A healthy sync folder answers the setup check", SafeFile.checkSync(folder))

    let hold = CoordinationHold(settings, folder.appendingPathComponent(".stringline-check"))
    var started = Date()
    var gaveUp = false
    do { try SafeFile.write(Data("new".utf8), to: settings) } catch SafeFile.Failure.notResponding { gaveUp = true } catch {}
    let waited = Date().timeIntervalSince(started)
    check("A save into a stuck sync folder gives up after the time limit instead of hanging", gaveUp && waited < 3, "gave up: \(gaveUp), waited \(waited)s")
    check("The file is left exactly as it was", (try? Data(contentsOf: settings)) == Data("old".utf8))
    check("No temporary copies are left in the folder", (try? fm.contentsOfDirectory(atPath: folder.path)) == ["settings.json"],
          "\((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])")
    check("The stall is remembered for the whole sync folder", SafeFile.isNotResponding(rates))

    started = Date()
    let read = SafeFile.read(settings)
    var quickWrite = false
    do { try SafeFile.write(Data("x".utf8), to: rates) } catch SafeFile.Failure.notResponding { quickWrite = true } catch {}
    let quick = Date().timeIntervalSince(started)
    if case .notResponding = read {} else { check("While it's stuck, reads say so", false, "\(read)") }
    check("While it's stuck, reads and writes fail at once instead of each waiting again", quickWrite && quick < 0.2, "\(quick)s")
    check("While it's stuck, the setup check says so", !SafeFile.checkSync(folder))
    check("…even for a folder setup hasn't made yet (it asks the nearest one that exists)",
          !SafeFile.checkSync(folder.appendingPathComponent("Stringline/PavingData", isDirectory: true)))
    check("A JSON load reports it as not responding, not as damaged or missing", {
        if case .notResponding = JSONFile.load(AppSettings.self, from: settings) { return true }
        return false
    }())

    hold.end()
    let deadline = Date().addingTimeInterval(5)
    while SafeFile.isNotResponding(settings), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    check("A background check notices when it answers again", !SafeFile.isNotResponding(settings))
    var savedAgain = false
    do { try SafeFile.write(Data("new".utf8), to: settings); savedAgain = true } catch {}
    check("Saving works again afterward", savedAgain && (try? Data(contentsOf: settings)) == Data("new".utf8))

    // An ordinary folder: a held file still times out, but nothing else is affected.
    let local = base.appendingPathComponent("held-local", isDirectory: true)
    try? fm.removeItem(at: local)
    try! fm.createDirectory(at: local, withIntermediateDirectories: true)
    let held = local.appendingPathComponent("a.json"), other = local.appendingPathComponent("b.json")
    let localHold = CoordinationHold(held, local.appendingPathComponent("unused"))
    var timedOut = false
    do { try SafeFile.write(Data("a".utf8), to: held) } catch SafeFile.Failure.notResponding { timedOut = true } catch {}
    var otherSaved = false
    do { try SafeFile.write(Data("b".utf8), to: other); otherSaved = true } catch {}
    localHold.end()
    check("In an ordinary folder a file held by another app times out without blocking other files", timedOut && otherSaved && !SafeFile.isNotResponding(other))
}

/// Starts writer processes and kills them at random moments, hundreds of times, then checks the file is always whole.
func runKillTest(_ base: URL, rounds: Int) {
    let fm = FileManager.default
    let folder = base.appendingPathComponent("torture", isDirectory: true)
    try? fm.removeItem(at: folder)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("payload.json")
    let me = URL(fileURLWithPath: CommandLine.arguments[0])
    var lastVersion = -1
    var whole = 0, wrong: [String] = [], went_back = 0, saves = 0
    let started = Date()
    for round in 0..<rounds {
        let writers = round % 5 == 4 ? 2 : 1          // every fifth round, two writers fight over the same file
        var processes: [Process] = []
        for w in 0..<writers {
            let p = Process()
            p.executableURL = me
            p.arguments = ["--writer", folder.path, String(lastVersion + 1 + w * 1_000_000)]
            try! p.run()
            processes.append(p)
        }
        usleep(UInt32.random(in: 3_000...70_000))
        for p in processes { kill(p.processIdentifier, SIGKILL) }
        for p in processes { p.waitUntilExit() }

        switch JSONFile.load(Payload.self, from: file) {
        case .missing where lastVersion < 0:
            continue
        case .ok(let payload, _, _):
            if payload.isWhole { whole += 1 } else { wrong.append("round \(round): not whole") }
            if writers == 1 && payload.version < lastVersion { went_back += 1 }
            saves += max(0, payload.version % 1_000_000 - lastVersion)
            lastVersion = payload.version % 1_000_000
        default:
            wrong.append("round \(round): couldn't read")
        }
    }
    let litter = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".saving") }
    check("Killed mid-save \(rounds) times (with two Macs' worth of writers every fifth round): the file was whole every time",
          wrong.isEmpty && whole > rounds * 9 / 10, "\(whole) whole, problems: \(wrong.prefix(5))")
    check("A save is never undone by a crash (the file only moves forward)", went_back == 0, "\(went_back) went back")
    check("No half-written temporary files are left behind", litter.isEmpty, "\(litter)")
    let journal = Journal(url: folder.appendingPathComponent("history.sqlite"), folderPath: folder.path)
    let newest = journal.versions(of: "payload.json").first.flatMap { journal.data($0.id) }.flatMap { JSONFile.decode(Payload.self, from: $0) }
    check("The SQLite history survived every kill and its newest entry reads correctly",
          journal.problem == nil && newest?.isWhole == true, journal.problem ?? "")
    print("      \(rounds) kills in \(Int(Date().timeIntervalSince(started)))s, about \(saves) completed saves, \(journal.count) history entries")
}

/// Prints "OK <files> <counter>" and exits 0 if every data file reads correctly, nothing is half-written,
/// the History database is sound and the save counter didn't go backwards. Otherwise prints what's wrong and exits 1.
func verifyFolder(_ folder: URL, minimumCounter: Int) -> Never {
    var problems: [String] = []
    let listing = DataFile.list(folder)
    for path in listing.files.sorted() {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)) else { problems.append("\(path): unreadable"); continue }
        func ok<T: Codable & DefaultInit>(_ type: T.Type) -> Bool { if case .ok = JSONFile.interpret(T.self, data) { return true }; return false }
        let whole: Bool
        switch DataFile(path: path)! {
        case .settings: whole = ok(AppSettings.self)
        case .rates: whole = ok(Rates.self)
        case .customer: whole = ok(Customer.self)
        case .job(_, let part):
            switch part {
            case .job: whole = ok(Job.self)
            case .takeoff: whole = ok(Takeoff.self)
            case .estimate: whole = ok(Estimate.self)
            case .logs: whole = ok(JobLogs.self)
            case .invoice: whole = ok(Invoice.self)
            }
        }
        if !whole { problems.append("\(path): damaged") }
    }
    if !listing.copies.isEmpty { problems.append("extra copies: \(listing.copies)") }
    let leftovers = (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".saving") }
    if !leftovers.isEmpty { problems.append("half-written temp files: \(leftovers)") }
    let counter = JSONFile.read(AppSettings.self, from: folder.appendingPathComponent("settings.json"))?.nextProposalNumber ?? -1
    if counter < minimumCounter { problems.append("saves went backwards: \(counter) < \(minimumCounter)") }
    let history = folder.deletingLastPathComponent().appendingPathComponent("Local/History")
    for name in (try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [] where name.hasSuffix(".sqlite") {
        let journal = Journal(url: history.appendingPathComponent(name), folderPath: folder.path)
        if let problem = journal.problem { problems.append("history: \(problem)") }
        journal.close()
    }
    if problems.isEmpty {
        print("OK \(listing.files.count) \(counter)")
        exit(0)
    }
    print("BAD " + problems.joined(separator: "; "))
    exit(1)
}
