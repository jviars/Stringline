import Foundation

/// Why Stringline couldn't open the remembered PavingData folder. Shown instead of setup,
/// so a folder that's offline or still syncing is never mistaken for a fresh start.
enum LaunchProblem: Equatable {
    case folderMissing(URL)
    case settingsMissing(URL)
    case settingsDownloading(URL)
    case settingsDamaged(URL)
    case settingsUnreadable(URL, String)
    case settingsNewer(URL)
    /// iCloud's sync service on this Mac isn't answering, so the folder can't be read yet.
    case syncNotResponding(URL)

    var folder: URL {
        switch self {
        case .folderMissing(let url), .settingsMissing(let url), .settingsDownloading(let url),
             .settingsDamaged(let url), .settingsUnreadable(let url, _), .settingsNewer(let url), .syncNotResponding(let url): url
        }
    }

    /// Problems that usually fix themselves once iCloud catches up, so Stringline keeps retrying.
    var retriesOnItsOwn: Bool {
        switch self {
        case .folderMissing, .settingsMissing, .settingsDownloading, .syncNotResponding: true
        default: false
        }
    }
}

/// Why a file is off limits right now. Stringline never writes over a file it couldn't read.
enum FileIssue: Equatable {
    case downloading
    /// iCloud's sync service on this Mac isn't answering.
    case syncNotResponding
    case damaged
    case unreadable(String)
    case newerVersion

    /// Clears up by itself (Stringline keeps checking), as opposed to needing the person to act.
    var waitsOnItsOwn: Bool { self == .downloading || self == .syncNotResponding }

    var short: String {
        switch self {
        case .downloading: "still downloading from iCloud"
        case .syncNotResponding: "waiting for iCloud Drive to respond"
        case .damaged: "damaged"
        case .unreadable: "can't be read"
        case .newerVersion: "saved by a newer Stringline"
        }
    }

    var explanation: String {
        switch self {
        case .downloading:
            "This file is in iCloud but hasn't come down to this Mac yet. It'll open by itself as soon as it arrives. Nothing is changed in the meantime."
        case .syncNotResponding:
            "iCloud Drive isn't responding on this Mac, so this file couldn't be read. Nothing is changed. It opens by itself when iCloud answers again. If it lasts, restarting the Mac usually clears it up."
        case .damaged:
            "This file can't be read, and there's no earlier copy of it on this Mac. Stringline hasn't touched it. You can look for a good copy in the backups folder."
        case .unreadable(let why):
            "macOS wouldn't let Stringline read this file (\(why)). Nothing is changed until it can."
        case .newerVersion:
            "Another Mac saved this with a newer version of Stringline. Update Stringline on this Mac to change it. Until then it stays exactly as it is."
        }
    }
}

/// Two versions of the same file. Both are kept in History whichever one is chosen.
struct DataConflict: Identifiable, Equatable {
    enum Source: Equatable {
        /// Changed in the folder (usually on another Mac) while this Mac had unsaved changes.
        case changedElsewhere
        /// iCloud kept a second copy, named like "estimate 2.json".
        case iCloudCopy(String)
    }

    let id = UUID()
    let path: String
    let title: String
    let source: Source
    let mine: Data?
    let mineDate: Date
    let theirs: Data?
    let theirsDate: Date?

    static func == (a: DataConflict, b: DataConflict) -> Bool { a.id == b.id }
}

struct HealthIssue: Identifiable, Equatable {
    enum Kind: Equatable {
        case file(String, FileIssue)
        case conflict(UUID)
        case duplicateFolder(String, original: String)
        case missingJob(folder: String)
        case missingFile(String)
        case unsavedLastTime(Int64, path: String)
        case otherMac
        case lowDisk
        case history
    }

    var id: String { "\(kind)" }
    let kind: Kind
    let title: String
    let detail: String
}

struct HealthReport: Equatable {
    var checkedAt = Date.now
    var files = 0
    var issues: [HealthIssue] = []
    var historyVersions = 0
    var localBackups = 0
    var freeSpace: Int64?

    var isHealthy: Bool { issues.isEmpty }
}

/// One-line descriptions of a file's contents, for History and the clash chooser.
enum VersionSummary {
    static func describe(_ file: DataFile?, _ data: Data) -> String {
        switch file {
        case .settings:
            guard let s = JSONFile.decode(AppSettings.self, from: data) else { return unreadable }
            return [s.company.name.isEmpty ? "No company name" : s.company.name, "\(s.crews.count) crews",
                    "next invoice \(s.nextInvoiceNumber)"].joined(separator: " · ")
        case .rates:
            guard let r = JSONFile.decode(Rates.self, from: data) else { return unreadable }
            return "\(r.prices.count) prices · \(Fmt.plain(r.factors.wastePct))% waste · \(Fmt.plain(r.factors.profitPct))% profit"
        case .customer:
            guard let c = JSONFile.decode(Customer.self, from: data) else { return unreadable }
            return [c.name, c.contact, c.phone].filter { !$0.isEmpty }.joined(separator: " · ")
        case .job(_, let part):
            switch part {
            case .job:
                guard let j = JSONFile.decode(Job.self, from: data) else { return unreadable }
                return "\(j.name) · \(j.stage.label)\(j.schedule.isEmpty ? "" : " · \(j.schedule.count) \(j.schedule.count == 1 ? "day" : "days") booked")"
            case .takeoff:
                guard let t = JSONFile.decode(Takeoff.self, from: data) else { return unreadable }
                let area = t.shapes.filter { $0.kind == .area }.reduce(0) { $0 + Geo.netAreaSqFt($1) }
                let lines = t.shapes.filter { $0.kind == .line }.reduce(0) { $0 + Geo.lengthFt($1.points) }
                var parts = ["\(t.shapes.count) \(t.shapes.count == 1 ? "shape" : "shapes")"]
                if area > 0 { parts.append("\(Fmt.number(area)) sq ft") }
                if lines > 0 { parts.append("\(Fmt.number(lines)) LF") }
                return parts.joined(separator: " · ")
            case .estimate:
                guard let e = JSONFile.decode(Estimate.self, from: data) else { return unreadable }
                guard let option = e.selected else { return "No options yet" }
                return "\(e.options.count) \(e.options.count == 1 ? "option" : "options") · \(option.title) \(Fmt.dollars(option.breakdown.priceCents, showCents: false))"
            case .logs:
                guard let l = JSONFile.decode(JobLogs.self, from: data) else { return unreadable }
                return l.entries.isEmpty ? "No daily logs" : "\(l.entries.count) daily \(l.entries.count == 1 ? "log" : "logs")"
            case .invoice:
                guard let i = JSONFile.decode(Invoice.self, from: data) else { return unreadable }
                return "Invoice \(i.number) · \(Fmt.dollars(i.amountCents)) · \(i.isPaid ? "paid" : "unpaid")"
            }
        case nil:
            return "\(data.count) bytes"
        }
    }

    private static let unreadable = "Can't be read"

    // MARK: - What changed

    struct Change: Hashable {
        let field: String
        let before: String
        let after: String
    }

    /// The fields that differ between two versions of a file, in words ("Notes: — → Gate code 4412").
    static func changes(from old: Data?, to new: Data?) -> [Change] {
        let a = old.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let b = new.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        var result: [Change] = []
        walk(a, b, prefix: "", into: &result)
        return result
    }

    private static let ignored: Set<String> = ["updated", "stageChanged", "schemaVersion", "id", "folderName", "selectedOptionID", "lastBackup"]

    private static func walk(_ a: [String: Any], _ b: [String: Any], prefix: String, into result: inout [Change]) {
        for key in Set(a.keys).union(b.keys).sorted() where !ignored.contains(key) {
            let name = prefix.isEmpty ? fieldName(key) : "\(prefix) › \(fieldName(key))"
            if let x = a[key] as? [String: Any], let y = b[key] as? [String: Any] {
                walk(x, y, prefix: name, into: &result)
                continue
            }
            let before = render(key, a[key]), after = render(key, b[key])
            guard before.fingerprint != after.fingerprint else { continue }
            let afterText = before.text == after.text ? "\(after.text), edited" : after.text
            result.append(Change(field: name, before: before.text, after: afterText))
        }
    }

    private static func render(_ key: String, _ value: Any?) -> (text: String, fingerprint: String) {
        guard let value, !(value is NSNull) else { return ("—", "nil") }
        let fingerprint = (try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        if let list = value as? [Any] {
            let noun = fieldName(key).lowercased()
            return (list.isEmpty ? "none" : "\(list.count) \(list.count == 1 ? singular(noun) : noun)", fingerprint)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return (number.boolValue ? "Yes" : "No", fingerprint) }
            if key.hasSuffix("Cents") { return (Fmt.dollars(number.intValue), fingerprint) }
            return (Fmt.plain(number.doubleValue), fingerprint)
        }
        if let text = value as? String {
            if key.hasSuffix("ID") { return ("set", fingerprint) }
            if key == "stage", let stage = Stage(rawValue: text) { return (stage.label, fingerprint) }
            if let date = ISO8601DateFormatter().date(from: text) { return (date.formatted(date: .abbreviated, time: .omitted), fingerprint) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return ("—", fingerprint) }
            return (trimmed.count > 70 ? String(trimmed.prefix(67)) + "…" : trimmed, fingerprint)
        }
        return ("changed", fingerprint)
    }

    private static let names: [String: String] = [
        "customerID": "Customer", "crewID": "Crew", "bidDue": "Bid due", "sentOn": "Sent", "completedOn": "Completed",
        "paidOn": "Paid", "amountCents": "Amount", "depositCents": "Deposit", "dueDays": "Due in (days)",
        "entries": "Daily logs", "shapes": "Shapes", "options": "Options", "prices": "Prices", "crews": "Crews",
        "schedule": "Days booked", "ticket": "811 ticket", "plantNote": "Plant order", "isSample": "Sample job",
        "nextInvoiceNumber": "Next invoice number", "nextProposalNumber": "Next proposal number",
    ]

    private static func fieldName(_ key: String) -> String {
        if let name = names[key] { return name }
        var words = ""
        for character in key {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(contentsOf: character.lowercased())
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func singular(_ noun: String) -> String {
        if noun.hasSuffix("ies") { return String(noun.dropLast(3)) + "y" }
        if noun.hasSuffix("s") { return String(noun.dropLast()) }
        return noun
    }
}
