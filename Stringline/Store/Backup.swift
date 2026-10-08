import Foundation

/// Nightly zip of the JSON files (photos and PDFs are skipped: they don't change
/// and iCloud keeps its own copies). The zip is kept in two places, the last 30 in each:
/// on this Mac (so trouble with the folder can't take the backups with it) and in PavingData/backups.
enum Backup {
    @discardableResult
    static func make(of root: URL, localCopies: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let stagingParent = fm.temporaryDirectory.appending(path: "StringlineBackup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staging = stagingParent.appending(path: "PavingData", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingParent) }

        let rootPath = root.standardizedFileURL.path
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath) else { continue }
                let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if relative == "backups" || relative.hasPrefix("backups/") {
                    walker.skipDescendants()
                    continue
                }
                guard url.pathExtension == "json", relative != DataFile.lockName else { continue }
                // Read through SafeFile so a file iCloud hasn't downloaded is skipped, not waited on.
                // If iCloud isn't answering at all, stop: a backup of nothing must never replace today's good one.
                let read = SafeFile.read(url)
                if case .notResponding = read { throw SafeFile.Failure.notResponding }
                guard case .bytes(let data) = read else { continue }
                let destination = staging.appending(path: relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination)
            }
        }

        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let name = "Stringline-\(stamp).zip"
        let zip = stagingParent.appending(path: name)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinatorError) { zipURL in
            do { try fm.copyItem(at: zipURL, to: zip) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
        let data = try Data(contentsOf: zip)

        if let localCopies {
            try fm.createDirectory(at: localCopies, withIntermediateDirectories: true)
            try SafeFile.write(data, to: localCopies.appending(path: name))
            prune(localCopies, keep: 30)
        }
        let backups = root.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let destination = backups.appending(path: name)
        try SafeFile.write(data, to: destination)
        prune(backups, keep: 30)
        return destination
    }

    private static func prune(_ folder: URL, keep: Int) {
        let fm = FileManager.default
        let zips = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "zip" && $0.lastPathComponent.hasPrefix("Stringline-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in zips.dropFirst(keep) {
            try? fm.removeItem(at: old)
        }
    }
}
