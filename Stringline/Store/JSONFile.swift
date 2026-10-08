import Foundation

/// Every saved model carries a schema version, so a file written by a newer Stringline
/// is never quietly rewritten (and stripped) by an older one.
protocol SchemaVersioned { var schemaVersion: Int { get } }

extension AppSettings: SchemaVersioned {}
extension Rates: SchemaVersioned {}
extension Customer: SchemaVersioned {}
extension Job: SchemaVersioned {}
extension Takeoff: SchemaVersioned {}
extension Estimate: SchemaVersioned {}
extension JobLogs: SchemaVersioned {}
extension Invoice: SchemaVersioned {}

/// Reads and writes the plain JSON files in the PavingData folder.
enum JSONFile {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Fields this version of Stringline doesn't know, kept so saving never strips them.
    typealias Extras = [String: Any]

    enum Loaded<T> {
        case missing
        case notDownloaded
        case unreadable(String)
        /// iCloud didn't answer in time. Nothing was read.
        case notResponding
        /// Written by a newer Stringline. Read-only here.
        case newer
        /// The bytes are there but aren't a readable file of this kind.
        case damaged(Data)
        case ok(T, Data, Extras)
    }

    // MARK: - Reading

    static func load<T: Codable & DefaultInit>(_ type: T.Type, from url: URL) -> Loaded<T> {
        switch SafeFile.read(url) {
        case .missing: return .missing
        case .notDownloaded: return .notDownloaded
        case .unreadable(let why): return .unreadable(why)
        case .notResponding: return .notResponding
        case .bytes(let data): return interpret(T.self, data)
        }
    }

    static func interpret<T: Codable & DefaultInit>(_ type: T.Type, _ data: Data) -> Loaded<T> {
        guard let value = decode(T.self, from: data) else { return .damaged(data) }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let fileVersion = raw["schemaVersion"] as? Int, let current = (T() as? SchemaVersioned)?.schemaVersion, fileVersion > current {
            return .newer
        }
        let known = (try? encoder.encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return .ok(value, data, unknownKeys(raw: raw, known: known))
    }

    /// Decodes a file. If keys are missing (written by an older version), fills them from defaults.
    static func decode<T: Codable & DefaultInit>(_ type: T.Type, from data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        if let value = try? decoder.decode(T.self, from: data) { return value }
        guard
            let defaultsData = try? encoder.encode(T()),
            let base = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
            let overlay = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let mergedData = try? JSONSerialization.data(withJSONObject: merge(base, overlay))
        else { return nil }
        return try? decoder.decode(T.self, from: mergedData)
    }

    static func read<T: Codable & DefaultInit>(_ type: T.Type, from url: URL) -> T? {
        if case .ok(let value, _, _) = load(T.self, from: url) { return value }
        return nil
    }

    static func exists(_ url: URL) -> Bool { SafeFile.exists(url) }

    // MARK: - Writing

    /// Encodes a value and proves it reads back as the same value before anything touches the disk.
    /// Fields from a newer version (`extras`) are carried along untouched.
    static func encode<T: Codable>(_ value: T, preserving extras: Extras? = nil, name: String = "File") throws -> Data {
        let data = try encoder.encode(value)
        let back = try decoder.decode(T.self, from: data)
        guard try encoder.encode(back) == data else { throw SafeFile.Failure.encodingMismatch(name) }
        guard let extras, !extras.isEmpty,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        let merged = try JSONSerialization.data(withJSONObject: inject(extras, into: object),
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard try encoder.encode(decoder.decode(T.self, from: merged)) == data else { throw SafeFile.Failure.encodingMismatch(name) }
        return merged
    }

    /// Durable, verified, atomic write (see `SafeFile.write`).
    static func write<T: Codable>(_ value: T, to url: URL) throws {
        try SafeFile.write(encode(value, name: url.lastPathComponent), to: url)
    }

    // MARK: - Helpers

    private static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let child = value as? [String: Any], let baseChild = base[key] as? [String: Any] {
                result[key] = merge(baseChild, child)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Keys in the file that disappear when this version reads and re-saves it.
    static func unknownKeys(raw: [String: Any], known: [String: Any]) -> Extras {
        var extras: Extras = [:]
        for (key, value) in raw {
            if let knownValue = known[key] {
                if let rawChild = value as? [String: Any], let knownChild = knownValue as? [String: Any] {
                    let nested = unknownKeys(raw: rawChild, known: knownChild)
                    if !nested.isEmpty { extras[key] = nested }
                }
            } else if !(value is NSNull) {
                extras[key] = value
            }
        }
        return extras
    }

    private static func inject(_ extras: Extras, into object: [String: Any]) -> [String: Any] {
        var result = object
        for (key, value) in extras {
            if let existing = result[key] as? [String: Any], let nested = value as? [String: Any] {
                result[key] = inject(nested, into: existing)
            } else if result[key] == nil {
                result[key] = value
            }
        }
        return result
    }
}
