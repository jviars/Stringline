import Foundation

/// The files that make up a job folder.
enum JobPart: String, CaseIterable, Hashable {
    case job, takeoff, estimate, logs, invoice

    var fileName: String { "\(rawValue).json" }

    var label: String {
        switch self {
        case .job: "Job details"
        case .takeoff: "Measurements"
        case .estimate: "Estimate"
        case .logs: "Daily logs"
        case .invoice: "Invoice"
        }
    }

    var isPlural: Bool { self == .job || self == .takeoff || self == .logs }
}

/// One data file in the PavingData folder, identified by its path relative to the folder.
enum DataFile: Hashable {
    case settings, rates
    case customer(UUID)
    case job(folder: String, part: JobPart)

    static let lockName = "in-use.json"

    init?(path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            switch parts[0] {
            case "settings.json": self = .settings
            case "rates.json": self = .rates
            default: return nil
            }
        case 2:
            guard parts[0] == "customers", parts[1].hasSuffix(".json"),
                  let id = UUID(uuidString: String(parts[1].dropLast(5))) else { return nil }
            self = .customer(id)
        case 3:
            guard parts[0] == "jobs", !parts[1].isEmpty, !parts[1].hasPrefix("."),
                  let part = JobPart.allCases.first(where: { $0.fileName == parts[2] }) else { return nil }
            self = .job(folder: parts[1], part: part)
        default:
            return nil
        }
    }

    var path: String {
        switch self {
        case .settings: "settings.json"
        case .rates: "rates.json"
        case .customer(let id): "customers/\(id.uuidString).json"
        case .job(let folder, let part): "jobs/\(folder)/\(part.fileName)"
        }
    }

    var jobFolder: String? {
        if case .job(let folder, _) = self { return folder }
        return nil
    }

    /// iCloud saves a clashing copy next to the original as "estimate 2.json".
    /// Returns the original's path, or nil if `path` isn't such a copy.
    static func conflictOriginal(of path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(5)
        guard let space = stem.lastIndex(of: " ") else { return nil }
        let number = stem[stem.index(after: space)...]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        parts[parts.count - 1] = "\(stem[..<space]).json"
        let original = parts.joined(separator: "/")
        return DataFile(path: original) != nil || original == lockName ? original : nil
    }

    /// Every data file and clashing copy in a PavingData folder, plus files iCloud hasn't downloaded yet.
    struct Listing {
        var files: Set<String> = []
        var placeholders: Set<String> = []
        /// Original path → the clashing copies iCloud made of it.
        var copies: [String: [String]] = [:]
        var lockCopies: [String] = []
        var jobFolders: [String] = []
    }

    static func list(_ root: URL) -> Listing {
        var listing = Listing()
        let fm = FileManager.default
        func scan(_ relativeFolder: String) {
            let folder = relativeFolder.isEmpty ? root : root.appending(path: relativeFolder, directoryHint: .isDirectory)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let prefix = relativeFolder.isEmpty ? "" : "\(relativeFolder)/"
                if let real = SafeFile.realName(ofPlaceholder: name) {
                    if DataFile(path: prefix + real) != nil { listing.placeholders.insert(prefix + real) }
                    continue
                }
                guard !name.hasPrefix("."), name.hasSuffix(".json") else { continue }
                let path = prefix + name
                if DataFile(path: path) != nil {
                    listing.files.insert(path)
                } else if let original = conflictOriginal(of: path) {
                    if original == lockName { listing.lockCopies.append(path) } else { listing.copies[original, default: []].append(path) }
                }
            }
        }
        scan("")
        scan("customers")
        let jobsDir = root.appending(path: "jobs", directoryHint: .isDirectory)
        let folders = ((try? fm.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
        listing.jobFolders = folders
        for folder in folders { scan("jobs/\(folder)") }
        return listing
    }
}
