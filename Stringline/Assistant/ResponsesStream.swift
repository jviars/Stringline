import Foundation

/// One server-sent event from OpenAI's Responses API stream.
struct ResponsesEvent {
    let type: String
    let payload: JSONValue

    /// Reads one line of the stream. Only `data: {…}` lines carry events.
    static func parse(line: String) -> ResponsesEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard body != "[DONE]", let json = try? JSONValue.parse(body), let type = json["type"]?.string else { return nil }
        return ResponsesEvent(type: type, payload: json)
    }
}

/// Collects a streamed response. Only `response.completed` counts as success.
struct ResponseAccumulator {
    enum Status: Equatable {
        case streaming
        case completed
        case incomplete(String)
        case failed(OpenAIError)
    }

    enum Update {
        case textDelta(itemID: String, delta: String)
        case itemStarted(JSONValue)
        case itemDone(JSONValue)
    }

    private(set) var status: Status = .streaming
    private(set) var itemsDone: [JSONValue] = []
    private(set) var final: JSONValue?
    private(set) var text: [String: String] = [:]

    /// The output items, as the final response lists them. ChatGPT plan responses can end with an empty
    /// list and rely on the items streamed along the way, so those are used whenever the final list is empty.
    var output: [JSONValue] {
        let listed = final?["output"]?.array ?? []
        return listed.isEmpty ? itemsDone : listed
    }

    var functionCalls: [JSONValue] { output.filter { $0["type"]?.string == "function_call" } }

    /// The assistant's visible text, in order.
    var replyText: String {
        output.filter { $0["type"]?.string == "message" }
            .flatMap { $0["content"]?.array ?? [] }
            .compactMap { part -> String? in part["type"]?.string == "output_text" ? part["text"]?.string : nil }
            .joined(separator: "\n\n")
    }

    @discardableResult
    mutating func consume(_ event: ResponsesEvent) -> Update? {
        let p = event.payload
        switch event.type {
        case "response.output_text.delta":
            guard let id = p["item_id"]?.string, let delta = p["delta"]?.string else { return nil }
            text[id, default: ""] += delta
            return .textDelta(itemID: id, delta: delta)
        case "response.output_item.added":
            return p["item"].map { .itemStarted($0) }
        case "response.output_item.done":
            guard let item = p["item"] else { return nil }
            itemsDone.append(item)
            return .itemDone(item)
        case "response.completed":
            final = p["response"]
            status = .completed
        case "response.incomplete":
            final = p["response"]
            status = .incomplete(p["response"]?["incomplete_details"]?["reason"]?.string ?? "unknown")
        case "response.failed":
            let error = p["response"]?["error"] ?? .null
            status = .failed(OpenAIError(status: nil, code: error["code"]?.string, message: error["message"]?.string, param: error["param"]?.string))
        case "error":
            let error = p["error"] ?? p
            status = .failed(OpenAIError(status: nil, code: error["code"]?.string, message: error["message"]?.string, param: error["param"]?.string))
        default:
            break
        }
        return nil
    }
}

/// An error from OpenAI, sorted into what Stringline should do about it.
struct OpenAIError: Error, Equatable, LocalizedError {
    var status: Int?
    var code: String?
    var message: String?
    var param: String?

    enum Kind: Equatable {
        case usageLimit          // stop and point to ChatGPT's usage page
        case tryLater            // keep the sign-in, back off and retry a little
        case notEligible         // explain, don't retry
        case unsupported         // drop the named part of the request and retry once
        case signInEnded         // sign in again
        case badKey              // the API key was refused
        case rateLimited         // ordinary rate limit (API key)
        case other
    }

    var kind: Kind {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .tryLater
        case "subscription_sharing_user_not_eligible", "subscription_sharing_route_not_supported",
             "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": return .notEligible
        case "subscription_sharing_unsupported_capability": return .unsupported
        case "subscription_sharing_invalid_user": return .signInEnded
        case "invalid_api_key": return .badKey
        case "rate_limit_exceeded": return .rateLimited
        case "insufficient_quota": return .usageLimit
        default: break
        }
        switch status {
        case 401: return .signInEnded
        case 429: return .rateLimited
        case 500, 502, 503, 504: return .tryLater
        default: return .other
        }
    }

    var errorDescription: String? {
        switch kind {
        case .usageLimit: return "You've reached the usage limit for Stringline on your ChatGPT plan. You can check or change it in ChatGPT's usage settings."
        case .tryLater: return "ChatGPT is busy right now. Try again in a minute."
        case .notEligible: return "ChatGPT won't let Stringline use this account's plan\(message.map { " (\($0))" } ?? ""). This happens with ChatGPT Business, Enterprise and Edu workspaces that don't allow apps to use the plan. In Settings › AI assistant, press Use a different account and pick a personal Plus or Pro account, or add an OpenAI API key."
        case .unsupported: return "ChatGPT doesn't allow part of this request from apps\(param.map { " (\($0))" } ?? "")."
        case .signInEnded: return "Your ChatGPT sign-in has ended. Continue with ChatGPT in Settings › AI assistant to reconnect."
        case .badKey: return "OpenAI didn't accept the API key. Check it in Settings › AI assistant."
        case .rateLimited: return "Too many requests at once. Wait a moment and try again."
        case .other: return message ?? "OpenAI returned an error\(status.map { " (\($0))" } ?? "")."
        }
    }

    /// Reads an error body: `{"error": {...}}` or `{"detail": "..."}`.
    static func from(status: Int, body: Data) -> OpenAIError {
        let json = try? JSONValue.parse(body)
        if let e = json?["error"], e.object != nil {
            return OpenAIError(status: status, code: e["code"]?.string ?? e["type"]?.string, message: e["message"]?.string, param: e["param"]?.string)
        }
        if let s = json?["error"]?.string {
            return OpenAIError(status: status, code: s, message: json?["error_description"]?.string, param: nil)
        }
        let detail = json?["detail"]?.string ?? String(data: body.prefix(300), encoding: .utf8)
        return OpenAIError(status: status, code: nil, message: detail?.isEmpty == false ? detail : nil, param: nil)
    }
}

/// A model the signed-in account can use.
struct AIModel: Codable, Hashable, Identifiable {
    var id: String { slug }
    let slug: String
    let name: String

    /// Reads `GET /v1/models`. Sign in with ChatGPT returns `models` (keep `visibility == "list"`);
    /// an API key returns the usual `data` list, filtered to chat models.
    static func parseList(_ data: Data) -> [AIModel] {
        guard let json = try? JSONValue.parse(data) else { return [] }
        if let models = json["models"]?.array {
            return models.compactMap { m in
                guard let slug = m["slug"]?.string ?? m["id"]?.string else { return nil }
                if let visibility = m["visibility"]?.string, visibility != "list" { return nil }
                return AIModel(slug: slug, name: m["display_name"]?.string ?? slug)
            }
        }
        let skip = ["audio", "realtime", "image", "tts", "transcribe", "embedding", "search", "moderation", "dall-e", "whisper", "instruct", "codex", "computer"]
        let ids = (json["data"]?.array ?? []).compactMap { $0["id"]?.string }
            .filter { id in id.hasPrefix("gpt-") && !skip.contains { id.contains($0) } && id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil }
        return ids.sorted { rank($0) > rank($1) }.map { AIModel(slug: $0, name: $0) }
    }

    /// Bigger version numbers first, full models before mini and nano.
    static func rank(_ id: String) -> Double {
        let digits = id.dropFirst(4).prefix { $0.isNumber || $0 == "." }
        var score = (Double(digits) ?? 0) * 10
        if id.contains("nano") { score -= 3 } else if id.contains("mini") { score -= 2 }
        if id.contains("chat") || id.contains("preview") { score -= 1 }
        return score
    }
}
