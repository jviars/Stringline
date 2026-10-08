import Foundation
import AppKit

/// This Mac's connection to OpenAI: Sign in with ChatGPT (uses the owner's ChatGPT plan),
/// or the owner's own OpenAI API key. Tokens and keys live in the Keychain, never in PavingData.
@Observable @MainActor
final class AIAccount {
    enum Billing: String, Codable { case chatGPTPlan, apiKey }

    enum Phase: Equatable {
        case idle
        case waitingForBrowser(URL)
        case finishing
    }

    struct Session: Codable, Equatable {
        var clientID: String
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Date
        var scopes: [String]
        var claims: IDTokenClaims

        var planAllowed: Bool { scopes.contains(OpenAIAuthConfig.planScope) }
    }

    /// Kept across sign-outs, as OpenAI asks: the stable host ID and the client ID issued at registration.
    struct Registration: Codable {
        var hostID: String
        var clientID: String?
    }

    enum Problem: Error, LocalizedError {
        case notConnected, declined(String, String?), noCode, noClientID, noIDToken, sessionEnded, clientRejected, server(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: "Connect ChatGPT or add an API key in Settings › AI assistant first."
            case .declined(let why, let detail): Self.declined(why, detail)
            case .noCode, .noClientID: "OpenAI's sign-in reply was missing something Stringline needs. Try again."
            case .noIDToken: "OpenAI didn't say who signed in. Try again."
            case .sessionEnded: "Your ChatGPT sign-in has ended. Continue with ChatGPT to reconnect."
            case .clientRejected: "OpenAI didn't recognize this Mac's earlier registration, so Stringline will register again. Press Continue with ChatGPT once more."
            case .server(let why): why
            }
        }

        private static func declined(_ why: String, _ detail: String?) -> String {
            let said = detail.map { " OpenAI said: “\($0)”" } ?? ""
            return why == "access_denied"
                ? "OpenAI didn't connect Stringline.\(said) If you pressed Cancel, that's all it was. If you signed in with a ChatGPT Business, Enterprise or Edu workspace, it may not allow apps to use the plan: press Use a different account and pick a personal Plus or Pro account, or add an OpenAI API key."
                : "OpenAI didn't finish the sign-in (\(why)).\(said) Try again, or use a different account."
        }
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { phaseStarted = phase == .idle ? nil : .now } }
    }
    /// When the current sign-in step began, so the panel can say how long it's been waiting.
    private(set) var phaseStarted: Date?
    private(set) var session: Session?
    private(set) var apiKeyHint: String?
    var preferAPIKey = false
    /// The last problem, in words, for Settings.
    var message: String?
    /// Called when what Stringline is signed in with changes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored let secrets: SecretStore
    @ObservationIgnored private var registration: Registration
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Session, Error>?
    @ObservationIgnored private var keys: [JWK] = []
    @ObservationIgnored var urlSession: URLSession = .shared
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private static let registrationAccount = "chatgpt-registration"
    private static let sessionAccount = "chatgpt-session"
    private static let apiKeyAccount = "openai-api-key"

    init(secrets: SecretStore) {
        self.secrets = secrets
        if let saved = secrets.readJSON(Registration.self, Self.registrationAccount) {
            registration = saved
        } else {
            registration = Registration(hostID: "urn:uuid:\(UUID().uuidString.lowercased())")
            try? secrets.writeJSON(registration, for: Self.registrationAccount)
        }
        session = secrets.readJSON(Session.self, Self.sessionAccount)
        apiKeyHint = secrets.read(Self.apiKeyAccount).flatMap { String(data: $0, encoding: .utf8) }.map(Self.hint)
    }

    // MARK: State

    var hasAPIKey: Bool { apiKeyHint != nil }
    var isSignedIn: Bool { session != nil }
    var isSigningIn: Bool { phase != .idle }

    var billing: Billing? {
        if preferAPIKey, hasAPIKey { return .apiKey }
        if session?.planAllowed == true { return .chatGPTPlan }
        if hasAPIKey { return .apiKey }
        return nil
    }

    var isReady: Bool { billing != nil }

    var displayName: String {
        guard let c = session?.claims else { return "" }
        if let name = c.name, !name.isEmpty { return name }
        return c.email ?? "ChatGPT account"
    }

    var initials: String {
        let words = displayName.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    static func hint(_ key: String) -> String { "…" + key.suffix(4) }

    // MARK: Sign in with ChatGPT

    /// Opens OpenAI's sign-in in the browser and waits for it to come back to 127.0.0.1.
    func signIn(forceConsent: Bool = false) {
        guard signInTask == nil else { return }
        message = nil
        signInTask = Task { [weak self] in
            await self?.runSignIn(forceConsent: forceConsent)
            self?.signInTask = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// True once this Mac has registered with OpenAI, which ties sign-ins to the account and workspace picked then.
    var hasRegistration: Bool { registration.clientID != nil }

    /// Starts over with a new registration, so OpenAI asks which account or workspace to use.
    /// (A registration stays tied to the workspace picked when it was made, such as a Business workspace.)
    func useDifferentAccount() {
        guard signInTask == nil else { return }
        Task {
            if session != nil { await signOut() }
            registration.clientID = nil
            try? secrets.writeJSON(registration, for: Self.registrationAccount)
            message = nil
            signIn()
        }
    }

    /// Opens the sign-in page again, if the browser tab was closed.
    func reopenSignInPage() {
        if case .waitingForBrowser(let url) = phase { openURL(url) }
    }

    private func runSignIn(forceConsent: Bool) async {
        let state = SecureRandom.token()
        let nonce = SecureRandom.token()
        let pkce = PKCE()
        let server = LoopbackServer { query in
            guard let got = query["state"], constantTimeEquals(got, state) else {
                return .init(finish: false, status: 400, title: "This sign-in link has expired",
                             message: "Go back to Stringline and press Continue with ChatGPT again.")
            }
            if let error = query["error"] {
                let detail = query["error_description"].map { " OpenAI said: \($0)." } ?? ""
                return .init(finish: true, status: 200, title: "Stringline wasn't connected",
                             message: (error == "access_denied" ? "Nothing was connected." : "The sign-in didn't finish (\(error)).") + detail + " Go back to Stringline to see what you can do next. You can close this tab.")
            }
            guard query["code"] != nil else {
                return .init(finish: false, status: 400, title: "Something was missing", message: "Go back to Stringline and try again.")
            }
            return .init(finish: true, status: 200, title: "You're signed in", message: "You can close this tab and go back to Stringline.")
        }
        defer {
            server.stop()
            phase = .idle
        }
        do {
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)\(OpenAIAuthConfig.callbackPath)"
            let request = AuthorizeRequest(clientID: registration.clientID, hostID: registration.hostID, redirectURI: redirect,
                                           state: state, nonce: nonce, pkce: pkce, forceConsent: forceConsent)
            phase = .waitingForBrowser(request.url)
            openURL(request.url)
            let query = try await server.waitForCallback(timeout: 600)
            if let error = query["error"] {
                let detail = query["error_description"].map { String($0.prefix(300)) }
                throw ["invalid_client", "unauthorized_client"].contains(error) ? Problem.clientRejected : Problem.declined(error, detail)
            }
            guard let code = query["code"] else { throw Problem.noCode }
            let clientID = query["client_id"] ?? registration.clientID
            guard let clientID, clientID != OpenAIAuthConfig.registrationClientID else { throw Problem.noClientID }
            if registration.clientID != clientID {
                registration.clientID = clientID
                try? secrets.writeJSON(registration, for: Self.registrationAccount)
            }
            phase = .finishing
            let tokens = try await post(OpenAIAuthConfig.tokenURL, [
                ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
                ("code_verifier", pkce.verifier), ("redirect_uri", redirect), ("resource", OpenAIAuthConfig.resource),
            ])
            guard let idToken = tokens.id_token else { throw Problem.noIDToken }
            let claims = try await validate(idToken, clientID: clientID, nonce: nonce)
            let session = Session(clientID: clientID, accessToken: tokens.access_token, refreshToken: tokens.refresh_token, idToken: idToken,
                                  expiresAt: Date().addingTimeInterval(tokens.expires_in ?? 3600), scopes: tokens.scopes, claims: claims)
            try secrets.writeJSON(session, for: Self.sessionAccount)
            self.session = session
            if !session.planAllowed {
                message = "You're signed in, but ChatGPT plan use wasn't allowed, so the assistant can't run on your plan yet. Press Allow plan use to ask again, or add an API key."
            }
            NSApp.activate(ignoringOtherApps: true)
            onChange?()
        } catch is CancellationError {
            // The person cancelled; leave things as they were.
        } catch Problem.clientRejected {
            // A registration from another account, or one OpenAI no longer knows: register again next time.
            registration.clientID = nil
            try? secrets.writeJSON(registration, for: Self.registrationAccount)
            message = Problem.clientRejected.errorDescription
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func validate(_ idToken: String, clientID: String, nonce: String?) async throws -> IDTokenClaims {
        if keys.isEmpty { keys = try await fetchKeys() }
        do {
            return try IDTokenValidator.validate(idToken, keys: keys, clientID: clientID, nonce: nonce)
        } catch IDTokenValidator.Problem.unknownKey {
            // OpenAI may have rotated its keys since they were fetched.
            keys = try await fetchKeys()
            return try IDTokenValidator.validate(idToken, keys: keys, clientID: clientID, nonce: nonce)
        }
    }

    private func fetchKeys() async throws -> [JWK] {
        var request = URLRequest(url: OpenAIAuthConfig.jwksURL)
        request.timeoutInterval = 20
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let set = try? JSONDecoder().decode(JWKSet.self, from: data) else {
            throw Problem.server("Couldn't get OpenAI's signing keys to check the sign-in.")
        }
        return set.keys
    }

    private struct HTTPFailure: Error {
        let status: Int
        let body: OAuthErrorBody?
    }

    private func post(_ url: URL, _ form: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormEncoding.encode(form).utf8)
        request.timeoutInterval = 30
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            if url == OpenAIAuthConfig.tokenURL, form.contains(where: { $0 == ("grant_type", "refresh_token") }) {
                throw HTTPFailure(status: status, body: body)
            }
            if body?.error == "invalid_grant" { throw Problem.server("The sign-in code had expired. Press Continue with ChatGPT to try again.") }
            if body?.error == "invalid_client" || body?.error == "unauthorized_client" { throw Problem.clientRejected }
            throw Problem.server("OpenAI couldn't finish the sign-in\(body.map { " (\($0.error_description ?? $0.error))" } ?? " (HTTP \(status))").")
        }
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) } catch { throw Problem.server("OpenAI's sign-in reply couldn't be read.") }
    }

    // MARK: Tokens

    /// The bearer token for the next request, refreshed first when it's about to run out.
    func bearerToken() async throws -> String {
        switch billing {
        case .apiKey:
            guard let key = secrets.read(Self.apiKeyAccount).flatMap({ String(data: $0, encoding: .utf8) }) else { throw Problem.notConnected }
            return key
        case .chatGPTPlan:
            guard let s = session else { throw Problem.notConnected }
            if s.expiresAt.timeIntervalSinceNow < 120 { return try await refreshed().accessToken }
            return s.accessToken
        case nil:
            throw Problem.notConnected
        }
    }

    /// After a 401: refresh once. Returns true when there's a new token to retry with.
    func recoverFromUnauthorized() async -> Bool {
        guard billing == .chatGPTPlan else { return false }
        do { _ = try await refreshed(); return true } catch { return false }
    }

    /// One refresh at a time, since each refresh replaces the refresh token.
    private func refreshed() async throws -> Session {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> Session {
        guard var s = session, let refresh = s.refreshToken else {
            endSession()
            throw Problem.sessionEnded
        }
        do {
            let tokens = try await post(OpenAIAuthConfig.tokenURL, [
                ("grant_type", "refresh_token"), ("client_id", s.clientID), ("refresh_token", refresh), ("resource", OpenAIAuthConfig.resource),
            ])
            s.accessToken = tokens.access_token
            if let next = tokens.refresh_token { s.refreshToken = next }
            if let id = tokens.id_token, let claims = try? await validate(id, clientID: s.clientID, nonce: nil) {
                s.idToken = id
                s.claims = claims
            }
            s.expiresAt = Date().addingTimeInterval(tokens.expires_in ?? 3600)
            if !tokens.scopes.isEmpty { s.scopes = tokens.scopes }
            try secrets.writeJSON(s, for: Self.sessionAccount)
            session = s
            return s
        } catch let failure as HTTPFailure {
            if failure.body?.endsSession == true || failure.status == 401 {
                endSession()
                throw Problem.sessionEnded
            }
            throw Problem.server("Couldn't renew the ChatGPT sign-in right now (HTTP \(failure.status)). It's kept; try again shortly.")
        }
    }

    /// The saved sign-in can't be used any more: forget the tokens, keep the registration.
    private func endSession() {
        secrets.delete(Self.sessionAccount)
        session = nil
        message = Problem.sessionEnded.errorDescription
        onChange?()
    }

    /// Signs out: revokes the session at OpenAI, then forgets the tokens on this Mac.
    func signOut() async {
        cancelSignIn()
        guard let s = session else { return }
        var revoked = s.refreshToken == nil
        if let refresh = s.refreshToken {
            for attempt in 0..<3 where !revoked {
                var request = URLRequest(url: OpenAIAuthConfig.revokeURL)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(FormEncoding.encode([("token", refresh), ("token_type_hint", "refresh_token"), ("client_id", s.clientID)]).utf8)
                request.timeoutInterval = 15
                if let (_, response) = try? await urlSession.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode {
                    if status == 200 { revoked = true }
                    if status < 500 { break }
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        secrets.delete(Self.sessionAccount)
        session = nil
        message = revoked ? nil : "Signed out on this Mac. OpenAI didn't confirm it, so you can also remove Stringline in ChatGPT's settings."
        onChange?()
    }

    #if DEBUG
    /// For the self-test: makes the saved sign-in look expired so the next request refreshes it.
    func expireForTesting() {
        session?.expiresAt = .distantPast
    }
    #endif

    // MARK: API key

    func saveAPIKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count >= 20, !key.contains(where: \.isWhitespace) else {
            throw Problem.server("That doesn't look like an OpenAI API key. Keys start with sk-.")
        }
        try secrets.write(Data(key.utf8), for: Self.apiKeyAccount)
        apiKeyHint = Self.hint(key)
        onChange?()
    }

    func removeAPIKey() {
        secrets.delete(Self.apiKeyAccount)
        apiKeyHint = nil
        onChange?()
    }
}
