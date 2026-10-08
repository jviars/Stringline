#if DEBUG
import SwiftUI

/// Debug-only mode for the app kill test (`scripts/kill-test.sh`), run with `-StringlineSaveLoop`.
/// Opens the folder in STRINGLINE_LOOP_FOLDER and edits and saves nonstop until the script force-quits it.
/// Every edit bumps `settings.nextProposalNumber`, so the script can check saves only ever move forward.
@MainActor
enum SaveLoop {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-StringlineSaveLoop") }

    static var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["STRINGLINE_LOOP_FOLDER"] ?? NSTemporaryDirectory().appending("StringlineLoop/PavingData"),
            isDirectory: true)
    }

    static func makeStore() -> AppStore {
        AppStore(isolated: true, localRoot: folder.deletingLastPathComponent().appending(path: "Local", directoryHint: .isDirectory),
                 machineID: "kill-test-mac", machineName: "Kill Test Mac")
    }

    static func run(store: AppStore) async {
        let status = folder.deletingLastPathComponent().appending(path: "status.txt")
        if FileManager.default.fileExists(atPath: folder.appending(path: "settings.json").path) {
            store.openFolder(folder)
        } else {
            store.settings.company.name = "Kill Test Paving"
            store.settings.onboardingComplete = true
            try? store.createDataFolder(at: folder)
            for name in ["North Lot", "South Lot", "Church Drive"] { store.createJob(name: name, services: [.sealcoat]) }
            store.flush()
        }
        // Opening after a crash must work normally: no problem screen, and this Mac's own stale lock must not pause saving.
        var report = "opened"
        if store.launchProblem != nil { report = "PROBLEM \(String(describing: store.launchProblem))" }
        if store.savingPaused != nil { report = "PAUSED by \(store.savingPaused!.machineName)" }
        if !store.conflicts.isEmpty { report = "CONFLICTS \(store.conflicts.map(\.title))" }
        try? report.write(to: status, atomically: true, encoding: .utf8)
        guard report == "opened" else { return }

        var rng = SystemRandomNumberGenerator()
        var step = 0
        while true {
            step += 1
            let ids = store.realJobs.map(\.id)
            guard let id = ids.randomElement(using: &rng) else { return }
            switch step % 4 {
            case 0:
                var job = store.job(id)!
                job.notes = String(repeating: "Crack seal and restripe. ", count: Int.random(in: 1...40, using: &rng))
                store.jobBinding(id).wrappedValue = job
            case 1:
                var takeoff = store.takeoffs[id] ?? Takeoff()
                var shape = TakeoffShape()
                shape.points = (0..<Int.random(in: 3...12, using: &rng)).map { i in
                    Coordinate(lat: 40 + Double(i) * 0.0001, lon: -83 + Double(step % 50) * 0.0001)
                }
                takeoff.shapes = Array((takeoff.shapes + [shape]).suffix(30))
                store.takeoffBinding(id).wrappedValue = takeoff
            case 2:
                var logs = store.logs[id] ?? JobLogs()
                logs.entries = Array((logs.entries + [DailyLog(day: Date().startOfDay, crewID: nil, tons: Double(step), hours: 8, weather: "", notes: "Step \(step)")]).suffix(60))
                store.logsBinding(id).wrappedValue = logs
            default:
                break
            }
            store.settings.nextProposalNumber += 1
            store.markDirty(.settings)
            store.flush()
            await Task.yield()
        }
    }
}
#endif
