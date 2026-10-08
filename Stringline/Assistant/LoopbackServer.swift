import Foundation
import Network

/// Listens on 127.0.0.1 (this Mac only) for the one browser redirect that finishes signing in.
/// Requests to any other path, or without the expected state, get an error page and are ignored.
final class LoopbackServer: @unchecked Sendable {
    struct Verdict {
        var finish: Bool
        var status: Int
        var title: String
        var message: String
    }

    enum Failure: Error, LocalizedError {
        case timedOut, couldNotListen(String)
        var errorDescription: String? {
            switch self {
            case .timedOut: "Signing in took too long. Press Continue with ChatGPT to try again."
            case .couldNotListen(let why): "Stringline couldn't get ready for the sign-in (\(why))."
            }
        }
    }

    private let queue = DispatchQueue(label: "app.stringline.loopback")
    private let path: String
    private let judge: @Sendable ([String: String]) -> Verdict
    private var listener: NWListener?
    /// Set once the listener is ready or has failed. Only touched on `queue`.
    private var started = false
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init(path: String = OpenAIAuthConfig.callbackPath, judge: @escaping @Sendable ([String: String]) -> Verdict) {
        self.path = path
        self.judge = judge
    }

    /// Starts listening on a free port on 127.0.0.1 and returns it.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { throw Failure.couldNotListen(error.localizedDescription) }
        self.listener = listener
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    if let port = listener.port?.rawValue, port != 0 { cont.resume(returning: port) }
                    else { cont.resume(throwing: Failure.couldNotListen("no port")) }
                case .failed(let error):
                    self.started = true
                    cont.resume(throwing: Failure.couldNotListen(error.localizedDescription))
                case .cancelled:
                    self.started = true
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the redirect and returns its query parameters.
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                queue.async {
                    if let result = self.result { cont.resume(with: result); return }
                    self.waiter = cont
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(Failure.timedOut)) }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.finish(.failure(CancellationError()))
        }
    }

    // MARK: - Connections (on `queue`)

    private func finish(_ outcome: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = outcome
        listener?.cancel()
        listener = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(with: outcome)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if buffer.count > 16_384 || isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let reply: Data
        if let request = LoopbackHTTP.parse(head), request.method == "GET", request.path == path, result == nil {
            let verdict = judge(request.query)
            reply = LoopbackHTTP.response(status: verdict.status, title: verdict.title, message: verdict.message)
            if verdict.finish { finish(.success(request.query)) }
        } else {
            reply = LoopbackHTTP.response(status: 404, title: "Nothing here", message: "This address is only used while signing in to Stringline.")
        }
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }
}
