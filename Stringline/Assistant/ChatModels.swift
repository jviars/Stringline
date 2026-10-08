import Foundation

/// Assistant preferences. Kept per Mac (UserDefaults), never in PavingData.
struct AssistantPrefs: Codable, Equatable {
    var defaultMode: AssistantMode = .chat
    var shareContact = false
    var model: String?
    var areas: Set<ToolArea> = Set(ToolArea.allCases)
    var planWelcomeSeen = false
    var preferAPIKey = false
    var webSearch = true
    var keepHistory = true
    /// Every area this version knows, so areas added later can start on for people who had everything on.
    var seenAreas: Set<ToolArea> = Set(ToolArea.allCases)

    init() {}

    /// Missing keys (from older versions) fall back to the defaults instead of losing everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssistantPrefs()
        defaultMode = (try? c.decodeIfPresent(AssistantMode.self, forKey: .defaultMode)) ?? d.defaultMode
        shareContact = (try? c.decodeIfPresent(Bool.self, forKey: .shareContact)) ?? d.shareContact
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        let seen = (try? c.decodeIfPresent(Set<ToolArea>.self, forKey: .seenAreas)) ?? ToolArea.original
        if let saved = try? c.decodeIfPresent(Set<ToolArea>.self, forKey: .areas) {
            // A new area starts on only if every area was on before; someone who turned some off decides for themselves.
            areas = saved.isSuperset(of: seen) ? saved.union(Set(ToolArea.allCases).subtracting(seen)) : saved
        } else {
            areas = d.areas
        }
        planWelcomeSeen = (try? c.decodeIfPresent(Bool.self, forKey: .planWelcomeSeen)) ?? d.planWelcomeSeen
        preferAPIKey = (try? c.decodeIfPresent(Bool.self, forKey: .preferAPIKey)) ?? d.preferAPIKey
        webSearch = (try? c.decodeIfPresent(Bool.self, forKey: .webSearch)) ?? d.webSearch
        keepHistory = (try? c.decodeIfPresent(Bool.self, forKey: .keepHistory)) ?? d.keepHistory
    }
}

/// A picture or PDF attached to a message.
struct Attachment: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case image, pdf }
    var id = UUID()
    let name: String
    let kind: Kind
    /// `data:` URL with the file. Empty once a chat is saved (only the preview is kept).
    var dataURL: String
    /// A small JPEG for the chat bubble.
    var preview: Data?

    var hasData: Bool { !dataURL.isEmpty }

    /// The Responses API input part for this file.
    var inputPart: JSONValue {
        switch kind {
        case .image: ["type": "input_image", "image_url": .string(dataURL), "detail": "auto"]
        case .pdf: ["type": "input_file", "filename": .string(name), "file_data": .string(dataURL)]
        }
    }

    /// What's left in the conversation once the file itself is dropped.
    var placeholderPart: JSONValue {
        ["type": "input_text", "text": .string("[\(kind == .image ? "Picture" : "PDF") attached earlier: \(name)]")]
    }
}

/// A web page the assistant's answer came from.
struct Source: Codable, Hashable {
    let url: String
    let title: String

    var host: String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }

    /// Only ordinary web links are ever opened.
    var safeURL: URL? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil else { return nil }
        return u
    }

    /// The url_citation annotations in a response's output.
    static func citations(in output: [JSONValue]) -> [Source] {
        var seen = Set<String>()
        var out: [Source] = []
        for item in output where item["type"]?.string == "message" {
            for part in item["content"]?.array ?? [] {
                for note in part["annotations"]?.array ?? [] where note["type"]?.string == "url_citation" {
                    guard let url = note["url"]?.string, !seen.contains(url) else { continue }
                    seen.insert(url)
                    out.append(Source(url: url, title: note["title"]?.string ?? url))
                }
            }
        }
        return out
    }
}

/// One step of an assistant run, shown in its progress card.
struct RunStep: Identifiable, Codable, Hashable {
    enum State: String, Codable { case done, failed }
    var id = UUID()
    var text: String
    var icon: String
    var state: State
}

struct RunLog: Codable, Hashable {
    enum State: String, Codable { case running, done, stopped, failed }
    var steps: [RunStep] = []
    var state: State = .running
    var started = Date()
    var ended: Date?
}

// MARK: - Markdown

/// The pieces of a reply, for showing lists and steps properly.
enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(Int, String)
    case bullets([String])
    case numbered(start: Int, [String])
    case quote(String)
    case code(String)
    case rule
}

enum Markdown {
    static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var numberedStart = 1
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(start: numberedStart, numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(raw)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if let level = heading(line) {
                flush()
                blocks.append(.heading(level, String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let item = bullet(line) {
                if !bullets.isEmpty { bullets.append(item); continue }
                flush()
                bullets = [item]
                continue
            }
            if let (n, item) = numberedItem(line) {
                if !numbered.isEmpty { numbered.append(item); continue }
                flush()
                numberedStart = n
                numbered = [item]
                continue
            }
            if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            // A line under a list item that isn't a new item continues it.
            if !bullets.isEmpty, raw.hasPrefix(" ") { bullets[bullets.count - 1] += " " + line; continue }
            if !numbered.isEmpty, raw.hasPrefix(" ") { numbered[numbered.count - 1] += " " + line; continue }
            if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (n, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    /// Plain text with markdown symbols removed, for reading aloud and copying.
    static func plain(_ text: String) -> String {
        blocks(text).map { block -> String in
            switch block {
            case .paragraph(let s), .quote(let s), .code(let s): return s
            case .heading(_, let s): return s
            case .bullets(let items): return items.map { "• \($0)" }.joined(separator: "\n")
            case .numbered(let start, let items): return items.enumerated().map { "\(start + $0.offset). \($0.element)" }.joined(separator: "\n")
            case .rule: return ""
            }
        }
        .joined(separator: "\n\n")
        .replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "__", with: "")
        .replacingOccurrences(of: "`", with: "")
    }
}

// MARK: - Saved chats

/// A conversation kept on this Mac (Application Support, never PavingData or iCloud).
struct SavedChat: Codable, Identifiable {
    enum Item: Codable, Hashable {
        case user(String, [Attachment])
        case reply(String, [Source])
        case run(RunLog)
        case note(String)
        case changes(title: String, lines: [String], state: String)
    }
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var mode: AssistantMode
    var items: [Item]
    var history: [JSONValue]
}

struct ChatSummary: Identifiable, Hashable, Codable {
    let id: UUID
    let title: String
    let updated: Date
}

/// Reads and writes saved chats, one file each, readable only by this user.
final class ChatArchive {
    let folder: URL
    let keep: Int

    init(folder: URL, keep: Int = 200) {
        self.folder = folder
        self.keep = keep
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    func save(_ chat: SavedChat) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(chat)
        let target = url(chat.id)
        try data.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        prune()
    }

    func load(_ id: UUID) -> SavedChat? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SavedChat.self, from: data)
    }

    func list() -> [ChatSummary] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { file in (try? Data(contentsOf: file)).flatMap { try? decoder.decode(ChatSummary.self, from: $0) } }
            .sorted { $0.updated > $1.updated }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }

    func deleteAll() {
        for chat in list() { delete(chat.id) }
    }

    private func prune() {
        let all = list()
        guard all.count > keep else { return }
        for old in all.dropFirst(keep) { delete(old.id) }
    }
}
