import Foundation

/// Talks to OpenAI's Responses API (`POST /v1/responses`, streamed) with the signed-in account.
@MainActor
struct OpenAIClient {
    let account: AIAccount
    var session: URLSession { account.urlSession }

    private func request(_ path: String, method: String = "GET") async throws -> URLRequest {
        var request = URLRequest(url: OpenAIAuthConfig.apiBase.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(try await account.bearerToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Checks an API key with OpenAI before it's saved.
    static func check(apiKey: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count >= 20, !key.contains(where: \.isWhitespace) else {
            throw AIAccount.Problem.server("That doesn't look like an OpenAI API key. Keys start with sk-.")
        }
        var req = URLRequest(url: OpenAIAuthConfig.apiBase.appending(path: "models"))
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenAIError.from(status: status, body: data) }
    }

    func listModels() async throws -> [AIModel] {
        var req = try await request("models")
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenAIError.from(status: status, body: data) }
        return AIModel.parseList(data)
    }

    /// Sends one request and reads the stream until the response completes, fails or stops early.
    func stream(_ body: JSONValue, onUpdate: (ResponseAccumulator.Update) -> Void) async throws -> ResponseAccumulator {
        var req = try await request("responses", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = body.data
        req.timeoutInterval = 180
        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 65_536 { break }
            }
            throw OpenAIError.from(status: status, body: data)
        }
        var accumulator = ResponseAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = ResponsesEvent.parse(line: line) else { continue }
            if let update = accumulator.consume(event) { onUpdate(update) }
            if accumulator.status != .streaming { return accumulator }
        }
        throw OpenAIError(status: nil, code: "stream_ended", message: "The connection dropped before the reply finished. Try again.", param: nil)
    }
}
