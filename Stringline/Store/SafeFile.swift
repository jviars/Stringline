import Foundation
import CryptoKit

/// Size, modification time and inode, for spotting a changed file without reading it.
struct FileStamp: Equatable {
    let size: Int64
    let modified: TimeInterval
    let inode: UInt64
}

/// Low-level reads and writes for the PavingData folder, built so a file is never half-written,
/// never written over without being read first, and never waited on while iCloud downloads it.
enum SafeFile {
    enum Read {
        /// No file and no iCloud placeholder: it's safe to create one.
        case missing
        /// iCloud hasn't brought this file to this Mac yet. A download has been requested.
        case notDownloaded
        /// The file is there but couldn't be read (permissions, disk error).
        case unreadable(String)
        /// iCloud (or the folder's sync service) didn't answer in time, so nothing was read. Try again later.
        case notResponding
        case bytes(Data)
    }

    enum Failure: LocalizedError {
        case verifyBeforeSwap(String)
        case verifyAfterSwap(String)
        case encodingMismatch(String)
        case notResponding

        var errorDescription: String? {
            switch self {
            case .notResponding: "iCloud Drive isn't responding on this Mac, so Stringline didn't wait on it."
            case .verifyBeforeSwap(let name): "\(name) didn't read back correctly, so the previous version was kept."
            case .verifyAfterSwap(let name): "\(name) couldn't be confirmed after saving. Your change is kept in History on this Mac."
            case .encodingMismatch(let name): "\(name) didn't convert cleanly, so it wasn't saved. The previous version was kept."
            }
        }
    }

    /// Paths the self-test pretends iCloud hasn't downloaded yet.
    static var simulatedNotDownloaded: Set<String> = []

    // MARK: - Reading

    /// Reads a file through file coordination, without ever waiting on an iCloud download.
    static func read(_ url: URL) -> Read {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if fm.fileExists(atPath: placeholder(for: url).path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return .notDownloaded
            }
            return .missing
        }
        if isNotDownloaded(url) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .notDownloaded
        }
        var result = Read.unreadable("The file couldn't be read.")
        do {
            try coordinated(url) { coordinator, began in
                var error: NSError?
                coordinator.coordinate(readingItemAt: url, options: [], error: &error) { readURL in
                    began()
                    do {
                        result = .bytes(try Data(contentsOf: readURL))
                    } catch {
                        result = .unreadable(error.localizedDescription)
                    }
                }
                return error
            }
        } catch Failure.notResponding {
            return .notResponding
        } catch {
            return .unreadable(error.localizedDescription)
        }
        return result
    }

    /// True when iCloud has the file but this Mac only has a stand-in for it ("Optimize Mac Storage").
    static func isNotDownloaded(_ url: URL) -> Bool {
        if simulatedNotDownloaded.contains(url.standardizedFileURL.path) { return true }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_flags & 0x4000_0000 != 0 { return true }   // SF_DATALESS
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// Older iCloud versions leave a hidden ".name.icloud" file in place of one that isn't downloaded.
    static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
    }

    /// "settings.json" for ".settings.json.icloud", otherwise nil.
    static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder(for: url).path)
    }

    static func stamp(_ url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileStamp(size: Int64(info.st_size), modified: modified, inode: UInt64(info.st_ino))
    }

    static func modified(_ url: URL) -> Date? {
        stamp(url).map { Date(timeIntervalSince1970: $0.modified) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Writing

    /// Writes a file so it's always either the old version or the new one, never a mix:
    /// 1. write a temporary copy and force it all the way onto the disk,
    /// 2. read it back and compare,
    /// 3. swap it into place in one step, coordinated with iCloud,
    /// 4. read the result back once more.
    static func write(_ data: Data, to url: URL) throws {
        if isNotResponding(url) { throw Failure.notResponding }
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { if let staging { try? fm.removeItem(at: staging) } }

        var temp = (staging ?? folder).appending(path: staging == nil ? hiddenTempName(for: url) : url.lastPathComponent)
        try writeDurably(data, to: temp)
        guard (try? Data(contentsOf: temp)) == data else {
            try? fm.removeItem(at: temp)
            throw Failure.verifyBeforeSwap(url.lastPathComponent)
        }

        var swapError: Error?
        do {
            try coordinated(url) { coordinator, began in
                var error: NSError?
                coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
                    began()
                    if Darwin.rename(temp.path, target.path) == 0 {
                        syncFolder(target.deletingLastPathComponent())
                        return
                    }
                    guard errno == EXDEV else {
                        swapError = posixError()
                        return
                    }
                    // The staging folder ended up on another disk: stage next to the file instead.
                    let local = target.deletingLastPathComponent().appending(path: hiddenTempName(for: target))
                    do {
                        try writeDurably(data, to: local)
                        try? fm.removeItem(at: temp)
                        temp = local
                        if Darwin.rename(local.path, target.path) != 0 { throw posixError() }
                        syncFolder(target.deletingLastPathComponent())
                    } catch {
                        try? fm.removeItem(at: local)
                        swapError = error
                    }
                }
                return error
            }
        } catch {
            swapError = error
        }
        if let swapError {
            try? fm.removeItem(at: temp)
            throw swapError
        }
        guard (try? Data(contentsOf: url)) == data else { throw Failure.verifyAfterSwap(url.lastPathComponent) }
    }

    /// Deletes a file, coordinated with iCloud.
    static func remove(_ url: URL) throws {
        var removeError: Error?
        try coordinated(url) { coordinator, began in
            var error: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
                began()
                do { try FileManager.default.removeItem(at: target) } catch { removeError = error }
            }
            return error
        }
        if let removeError { throw removeError }
    }

    /// Moves a file or folder, coordinated with iCloud.
    static func move(_ url: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var moveError: Error?
        try coordinated(url) { coordinator, began in
            var error: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error) { from, to in
                began()
                do { try FileManager.default.moveItem(at: from, to: to) } catch { moveError = error }
            }
            return error
        }
        if let moveError { throw moveError }
    }

    // MARK: - When iCloud stops answering

    /// How long a coordinated read or write may wait for iCloud to let it start. iCloud's sync service
    /// can get stuck (after the account ran out of space, or when it keeps crashing), and file
    /// coordination would then wait forever and freeze the app.
    static var coordinationTimeout: TimeInterval = 6
    /// How often a sync service that stopped answering is checked again, in the background.
    static var recheckInterval: TimeInterval = 5
    /// Folders the tests treat like iCloud Drive, so a stall there is remembered.
    static var testSyncFolders: [String] = []
    /// Posted on the main thread when a sync service that wasn't answering answers again.
    static let syncRecovered = Notification.Name("SafeFile.syncRecovered")

    private static let stallLock = NSLock()
    /// Sync areas known not to be answering, each with a folder to check again.
    private static var stalled: [String: URL] = [:]

    /// The synced area a file is in (iCloud Drive, or a provider such as Dropbox), or nil for an ordinary folder.
    static func syncRoot(of url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if let folder = testSyncFolders.first(where: { path.hasPrefix($0) }) { return folder }
        if let range = path.range(of: "/Library/Mobile Documents") { return String(path[..<range.upperBound]) }
        if let range = path.range(of: "/Library/CloudStorage/") {
            return String(path[..<range.upperBound]) + path[range.upperBound...].prefix { $0 != "/" }
        }
        return nil
    }

    /// True while the sync service for this file's folder is known not to be answering.
    /// Reads and writes there fail at once instead of waiting again.
    static func isNotResponding(_ url: URL) -> Bool {
        guard let root = syncRoot(of: url) else { return false }
        stallLock.lock()
        defer { stallLock.unlock() }
        return stalled[root] != nil
    }

    /// Checks whether the sync service will let Stringline write in `folder`, without writing anything.
    /// Waits up to `coordinationTimeout`, so call it off the main thread.
    static func checkSync(_ folder: URL) -> Bool {
        let answered = answers(folder)
        if let root = syncRoot(of: folder) {
            if answered { clearStall(root) } else { markStalled(root, recheck: folder) }
        }
        return answered
    }

    private static func answers(_ folder: URL) -> Bool {
        // Asking about a folder that doesn't exist yet never reaches the sync service, so ask the nearest one that does.
        var place = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: place.path), place.pathComponents.count > 2 { place.deleteLastPathComponent() }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let giveUp = DispatchWorkItem { coordinator.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + coordinationTimeout, execute: giveUp)
        var began = false
        var error: NSError?
        coordinator.coordinate(writingItemAt: place.appending(path: ".stringline-check"), options: .forReplacing, error: &error) { _ in began = true }
        giveUp.cancel()
        return began
    }

    /// Runs one coordinated file operation, giving up if the sync service doesn't let it start in time.
    /// `operation` calls `began()` first thing inside its accessor and returns the coordinator's error.
    private static func coordinated(_ url: URL, _ operation: (NSFileCoordinator, () -> Void) -> NSError?) throws {
        let root = syncRoot(of: url)
        if root != nil, isNotResponding(url) { throw Failure.notResponding }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let giveUp = DispatchWorkItem { coordinator.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + coordinationTimeout, execute: giveUp)
        var began = false
        let error = operation(coordinator) {
            giveUp.cancel()
            began = true
        }
        giveUp.cancel()
        if !began, let error, error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError {
            if let root { markStalled(root, recheck: url.deletingLastPathComponent()) }
            throw Failure.notResponding
        }
        if let error { throw error }
    }

    private static func markStalled(_ root: String, recheck folder: URL) {
        stallLock.lock()
        let isNew = stalled[root] == nil
        stalled[root] = folder
        stallLock.unlock()
        guard isNew else { return }
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: recheckInterval)
                stallLock.lock()
                let folder = stalled[root]
                stallLock.unlock()
                guard let folder else { return }
                if answers(folder) {
                    clearStall(root)
                    return
                }
            }
        }
    }

    private static func clearStall(_ root: String) {
        stallLock.lock()
        let was = stalled.removeValue(forKey: root) != nil
        stallLock.unlock()
        if was { DispatchQueue.main.async { NotificationCenter.default.post(name: syncRecovered, object: nil) } }
    }

    private static func hiddenTempName(for url: URL) -> String {
        ".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).saving"
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
        // F_FULLFSYNC asks the drive itself to commit, not just the OS. Some disks only support fsync.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw posixError() }
    }

    private static func syncFolder(_ folder: URL) {
        let fd = open(folder.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
        close(fd)
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
