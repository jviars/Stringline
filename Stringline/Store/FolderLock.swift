import Foundation
import SystemConfiguration
import CoreServices

/// Who has Stringline open on a PavingData folder, written to "in-use.json" in that folder.
struct LockInfo: Codable, Equatable {
    var machineID: String
    var machineName: String
    var since: Date
    var heartbeat: Date
}

/// One Mac saves at a time. The Mac that has the folder open refreshes `in-use.json` every minute;
/// another Mac that finds a fresh one opens with saving paused until the person chooses to switch.
struct FolderLock {
    /// How often the open Mac refreshes the lock, and how old it can get before it's ignored
    /// (the other Mac crashed, lost power or went offline). The self-test shortens both.
    static var interval: TimeInterval = 60
    static var staleAfter: TimeInterval = 5 * 60

    let folder: URL
    let machineID: String
    let machineName: String

    var url: URL { folder.appending(path: DataFile.lockName) }

    func current() -> LockInfo? {
        guard case .bytes(let data) = SafeFile.read(url) else { return nil }
        return try? JSONFile.decoder.decode(LockInfo.self, from: data)
    }

    /// Another Mac that has Stringline open on this folder right now, if any.
    func otherOwner(now: Date = .now) -> LockInfo? {
        guard let info = current(), info.machineID != machineID, now.timeIntervalSince(info.heartbeat) < Self.staleAfter else { return nil }
        return info
    }

    func claim(now: Date = .now) throws {
        try write(LockInfo(machineID: machineID, machineName: machineName, since: now, heartbeat: now))
    }

    /// Refreshes this Mac's heartbeat. If another Mac has taken over, returns its lock and leaves it alone.
    func beat(now: Date = .now) throws -> LockInfo? {
        let existing = current()
        if let existing, existing.machineID != machineID {
            if now.timeIntervalSince(existing.heartbeat) < Self.staleAfter { return existing }
        }
        let since = existing?.machineID == machineID ? existing!.since : now
        try write(LockInfo(machineID: machineID, machineName: machineName, since: since, heartbeat: now))
        return nil
    }

    func release() {
        guard current()?.machineID == machineID else { return }
        try? SafeFile.remove(url)
    }

    private func write(_ info: LockInfo) throws {
        try SafeFile.write(JSONFile.encode(info, name: DataFile.lockName), to: url)
    }

    /// The name people gave this Mac in System Settings › General › Sharing.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Another Mac"
    }
}

/// Calls back (on the main queue) whenever anything inside a folder changes, including changes iCloud brings in.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init(folder: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
