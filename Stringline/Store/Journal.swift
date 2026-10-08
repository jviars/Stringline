import Foundation
import SQLite3

/// Every version of every data file, kept in a SQLite database on this Mac only.
/// It lives in ~/Library/Application Support, never in iCloud Drive: syncing a live database
/// file by file is a well-known way to corrupt it. The JSON files stay the real record;
/// this is the safety net for rolling back or recovering them.
final class Journal: @unchecked Sendable {
    enum Reason: String, CaseIterable {
        case loaded, saved, unsaved, external, restored, deleted, discarded
        case conflictMine = "conflict-mine"
        case setAside = "set-aside"

        var label: String {
            switch self {
            case .loaded: "Opened"
            case .saved: "Saved"
            case .unsaved: "Not saved"
            case .external: "Changed on another Mac"
            case .restored: "Restored"
            case .deleted: "Deleted"
            case .discarded: "Not saved (dismissed)"
            case .conflictMine: "This Mac's version"
            case .setAside: "Set aside"
            }
        }

        /// Kept as their own entry even when the content matches the newest version.
        var isMarker: Bool { [.unsaved, .deleted, .conflictMine, .setAside].contains(self) }
    }

    struct Version: Identifiable, Hashable {
        let id: Int64
        let path: String
        let savedAt: Date
        let reason: Reason
        let sha: String
        let size: Int
        let label: String
    }

    let url: URL
    private(set) var problem: String?
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.stringline.journal")
    private var newest: [String: (sha: String, reason: Reason, id: Int64)] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (or creates) the history database. A damaged database is moved aside and started fresh,
    /// since the data files themselves don't depend on it.
    init(url: URL, folderPath: String) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !open() {
            close()
            let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path + suffix)
                let aside = url.deletingLastPathComponent().appending(path: "damaged-\(stamp)-\(url.lastPathComponent)\(suffix)")
                try? FileManager.default.moveItem(at: file, to: aside)
            }
            problem = "The history on this Mac was damaged, so a fresh one was started. Your data files weren't affected."
            if !open() {
                close()
                problem = "History on this Mac couldn't be opened. Your data files are still saved normally."
                return
            }
        }
        execute("INSERT OR REPLACE INTO meta(key, value) VALUES('folder', ?)", [.text(folderPath)])
        loadNewest()
    }

    deinit { close() }

    var isOpen: Bool { queue.sync { db != nil } }

    // MARK: - Recording

    /// Adds a version unless it matches the newest one for that file. Returns the new row's id.
    @discardableResult
    func record(_ path: String, _ data: Data, reason: Reason, label: String, at date: Date = .now) -> Int64? {
        queue.sync {
            guard db != nil else { return nil }
            let sha = SafeFile.sha256(data)
            if !reason.isMarker, let latest = newest[path], latest.sha == sha {
                // Found on disk exactly as last recorded: if that save was never confirmed, it did land.
                if latest.reason == .unsaved && (reason == .loaded || reason == .saved) {
                    runLocked("UPDATE versions SET reason = 'saved' WHERE id = ?", [.int(latest.id)])
                    newest[path] = (sha, .saved, latest.id)
                }
                return nil
            }
            guard let blob = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
            let ok = runLocked("INSERT INTO versions(path, saved_at, reason, sha, size, label, content) VALUES(?, ?, ?, ?, ?, ?, ?)",
                               [.text(path), .real(date.timeIntervalSince1970), .text(reason.rawValue), .text(sha),
                                .int(Int64(data.count)), .text(label), .blob(blob)])
            guard ok else { return nil }
            let id = sqlite3_last_insert_rowid(db)
            newest[path] = (sha, reason, id)
            return id
        }
    }

    func mark(_ id: Int64, as reason: Reason) {
        queue.sync {
            runLocked("UPDATE versions SET reason = ? WHERE id = ?", [.text(reason.rawValue), .int(id)])
            if let entry = newest.first(where: { $0.value.id == id }) { newest[entry.key] = (entry.value.sha, reason, id) }
        }
    }

    // MARK: - Reading

    func versions(of path: String) -> [Version] {
        query("SELECT id, path, saved_at, reason, sha, size, label FROM versions WHERE path = ? ORDER BY id DESC", [.text(path)], row: version)
    }

    func data(_ id: Int64) -> Data? {
        let blobs: [Data] = query("SELECT content FROM versions WHERE id = ?", [.int(id)]) { statement in
            guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
        guard let blob = blobs.first else { return nil }
        return try? (blob as NSData).decompressed(using: .zlib) as Data
    }

    /// The newest version of every file this history knows about.
    func latestVersions() -> [Version] {
        query("""
            SELECT v.id, v.path, v.saved_at, v.reason, v.sha, v.size, v.label FROM versions v
            JOIN (SELECT MAX(id) AS id FROM versions GROUP BY path) newest ON newest.id = v.id
            ORDER BY v.path
            """, [], row: version)
    }

    /// The newest version of a file that was really in the folder and passes `accept` (for example, one that reads correctly).
    /// Skips versions that never made it to disk or were set aside.
    func latestGood(_ path: String, accept: (Data) -> Bool) -> (Version, Data)? {
        let skip: Set<Reason> = [.deleted, .setAside, .discarded, .unsaved, .conflictMine]
        for version in versions(of: path) where !skip.contains(version.reason) {
            if let data = data(version.id), accept(data) { return (version, data) }
        }
        return nil
    }

    var count: Int {
        query("SELECT COUNT(*) FROM versions", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    // MARK: - Thinning

    /// Keeps every version from the last two weeks, one an hour back to 90 days, then one a day for two years.
    /// The newest version of every file is always kept, and marked versions (not saved, deleted,
    /// this Mac's side of a clash) are kept whole for 90 days.
    static func idsToThin(_ rows: [(id: Int64, path: String, savedAt: Date, reason: Reason)], now: Date) -> [Int64] {
        let day: TimeInterval = 86_400
        var remove: [Int64] = []
        for (_, group) in Dictionary(grouping: rows, by: \.path) {
            let sorted = group.sorted { $0.savedAt == $1.savedAt ? $0.id > $1.id : $0.savedAt > $1.savedAt }
            var hours = Set<Int>(), days = Set<Int>()
            for (index, row) in sorted.enumerated() {
                if index == 0 { continue }
                let age = now.timeIntervalSince(row.savedAt)
                if age < 14 * day { continue }
                if row.reason.isMarker && age < 90 * day { continue }
                if age < 90 * day {
                    if !hours.insert(Int(row.savedAt.timeIntervalSince1970 / 3600)).inserted { remove.append(row.id) }
                } else if age < 730 * day {
                    if !days.insert(Int(row.savedAt.timeIntervalSince1970 / day)).inserted { remove.append(row.id) }
                } else {
                    remove.append(row.id)
                }
            }
        }
        return remove
    }

    func thin(now: Date = .now) {
        let rows: [(id: Int64, path: String, savedAt: Date, reason: Reason)] = query("SELECT id, path, saved_at, reason FROM versions", []) { s in
            (sqlite3_column_int64(s, 0), Self.text(s, 1), Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
             Reason(rawValue: Self.text(s, 3)) ?? .saved)
        }
        let remove = Self.idsToThin(rows, now: now)
        guard !remove.isEmpty else { return }
        queue.sync {
            runLocked("BEGIN", [])
            for id in remove { runLocked("DELETE FROM versions WHERE id = ?", [.int(id)]) }
            runLocked("COMMIT", [])
            runLocked("PRAGMA incremental_vacuum", [])
        }
    }

    func close() {
        queue.sync {
            if let db { sqlite3_close_v2(db) }
            db = nil
        }
    }

    // MARK: - SQLite plumbing

    private enum Value {
        case text(String), int(Int64), real(Double), blob(Data)
    }

    private func open() -> Bool {
        queue.sync {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return false }
            sqlite3_busy_timeout(db, 3000)
            runLocked("PRAGMA auto_vacuum = INCREMENTAL", [])
            runLocked("PRAGMA journal_mode = WAL", [])
            runLocked("PRAGMA synchronous = FULL", [])
            runLocked("PRAGMA fullfsync = ON", [])
            runLocked("PRAGMA checkpoint_fullfsync = ON", [])
            var check = "not ok"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
                check = Self.text(statement, 0)
            }
            sqlite3_finalize(statement)
            guard check == "ok" else { return false }
            return runLocked("""
                CREATE TABLE IF NOT EXISTS versions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT NOT NULL,
                    saved_at REAL NOT NULL,
                    reason TEXT NOT NULL,
                    sha TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    label TEXT NOT NULL DEFAULT '',
                    content BLOB NOT NULL)
                """, [])
                && runLocked("CREATE INDEX IF NOT EXISTS versions_by_path ON versions(path, id)", [])
                && runLocked("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)", [])
        }
    }

    private func loadNewest() {
        let rows: [(String, String, Reason, Int64)] = query("""
            SELECT v.path, v.sha, v.reason, v.id FROM versions v
            JOIN (SELECT MAX(id) AS id FROM versions GROUP BY path) newest ON newest.id = v.id
            """, []) { s in (Self.text(s, 0), Self.text(s, 1), Reason(rawValue: Self.text(s, 2)) ?? .saved, sqlite3_column_int64(s, 3)) }
        queue.sync {
            for (path, sha, reason, id) in rows { newest[path] = (sha, reason, id) }
        }
    }

    private func execute(_ sql: String, _ values: [Value]) {
        queue.sync { _ = runLocked(sql, values) }
    }

    @discardableResult
    private func runLocked(_ sql: String, _ values: [Value]) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            problem = "History error: \(String(cString: sqlite3_errmsg(db)))"
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        if result != SQLITE_DONE {
            problem = "History error: \(String(cString: sqlite3_errmsg(db)))"
            return false
        }
        return true
    }

    private func query<T>(_ sql: String, _ values: [Value], row: (OpaquePointer?) -> T) -> [T] {
        queue.sync {
            guard let db else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            bind(statement, values)
            var rows: [T] = []
            while sqlite3_step(statement) == SQLITE_ROW { rows.append(row(statement)) }
            return rows
        }
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Value]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .int(let number): sqlite3_bind_int64(statement, position, number)
            case .real(let number): sqlite3_bind_double(statement, position, number)
            case .blob(let data) where data.isEmpty:
                sqlite3_bind_zeroblob(statement, position, 0)
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), Self.transient) }
            }
        }
    }

    private func version(_ s: OpaquePointer?) -> Version {
        Version(id: sqlite3_column_int64(s, 0), path: Self.text(s, 1), savedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                reason: Reason(rawValue: Self.text(s, 3)) ?? .saved, sha: Self.text(s, 4), size: Int(sqlite3_column_int64(s, 5)), label: Self.text(s, 6))
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
