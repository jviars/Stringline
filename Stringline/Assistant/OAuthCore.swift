import Foundation
import CryptoKit
import Security

/// "Sign in with ChatGPT" for apps that run on the owner's own Mac, as documented at
/// developers.openai.com/siwc: system browser, loopback redirect to 127.0.0.1, PKCE (S256),
/// dynamic client registration, and an ID token checked against OpenAI's published keys.
enum OpenAIAuthConfig {
    static let issuer = "https://auth.openai.com"
    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let revokeURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", planScope]
    /// The client ID used only for the very first sign-in, which registers Stringline and returns its own ID.
    static let registrationClientID = "dynamic_agent_client"
    static let agentName = "Stringline"
    static let callbackPath = "/auth/callback"
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    static let apiBase = URL(string: "https://api.openai.com/v1")!
}

// MARK: - Encoding helpers

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

enum SecureRandom {
    static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "No secure random bytes")
        return data
    }

    /// A URL-safe random string with `count` bytes of entropy.
    static func token(_ count: Int = 32) -> String { Base64URL.encode(bytes(count)) }
}

/// Compares secrets without leaking where they first differ.
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
}

enum FormEncoding {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// `a=1&b=two%20words`, in the order given.
    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func decode(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pieces[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            let value = pieces.count > 1 ? (String(pieces[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
            if !key.isEmpty, out[key] == nil { out[key] = value }
        }
        return out
    }
}

// MARK: - PKCE

struct PKCE: Hashable {
    let verifier: String
    let challenge: String

    init() { self.init(verifier: SecureRandom.token(32)) }

    init(verifier: String) {
        self.verifier = verifier
        challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

// MARK: - Authorize URL

struct AuthorizeRequest {
    /// The ID OpenAI issued at the first sign-in, or nil to register.
    var clientID: String?
    var hostID: String
    var redirectURI: String
    var state: String
    var nonce: String
    var pkce: PKCE
    var forceConsent = false

    var url: URL {
        var pairs: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientID ?? OpenAIAuthConfig.registrationClientID),
        ]
        if clientID == nil { pairs.append(("agent_name_hint", OpenAIAuthConfig.agentName)) }
        pairs += [
            ("ext_agent_host_id", hostID),
            ("redirect_uri", redirectURI),
            ("scope", OpenAIAuthConfig.scopes.joined(separator: " ")),
            ("resource", OpenAIAuthConfig.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", pkce.challenge),
        ]
        if forceConsent { pairs.append(("prompt", "consent")) }
        var components = URLComponents(url: OpenAIAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = FormEncoding.encode(pairs)
        return components.url!
    }
}

// MARK: - Token endpoint

struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let token_type: String?
    let expires_in: Double?
    let scope: String?

    var scopes: [String] { (scope ?? "").split(separator: " ").map(String.init) }
}

struct OAuthErrorBody: Decodable {
    let error: String
    let error_description: String?

    /// Refresh errors after which the saved sign-in can't be used again.
    var endsSession: Bool {
        ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
         "refresh_token_invalidated", "refresh_token_reused"].contains(error)
    }
}

// MARK: - ID token (JWT, RS256)

struct JWT {
    let header: JSONValue
    let claims: JSONValue
    let signingInput: Data
    let signature: Data

    enum Problem: Error { case malformed }

    init(_ token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let h = Base64URL.decode(parts[0]), let c = Base64URL.decode(parts[1]), let s = Base64URL.decode(parts[2]),
              let header = try? JSONValue.parse(h), let claims = try? JSONValue.parse(c) else { throw Problem.malformed }
        self.header = header
        self.claims = claims
        signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        signature = s
    }
}

struct JWK: Codable, Hashable {
    let kty: String
    let kid: String?
    let n: String?
    let e: String?
    let alg: String?
    let use: String?
}

struct JWKSet: Codable { let keys: [JWK] }

struct IDTokenClaims: Codable, Hashable {
    var sub: String
    var email: String?
    var name: String?
    var picture: String?
}

enum IDTokenValidator {
    enum Problem: Error, LocalizedError {
        case malformed, unsupportedAlgorithm, unknownKey, badSignature, wrongIssuer, wrongAudience, expired, wrongNonce, noSubject
        var errorDescription: String? {
            switch self {
            case .malformed: "OpenAI's sign-in reply couldn't be read."
            case .unsupportedAlgorithm, .unknownKey, .badSignature: "OpenAI's sign-in reply didn't carry a valid signature."
            case .wrongIssuer, .wrongAudience, .noSubject: "The sign-in reply wasn't meant for Stringline."
            case .expired: "The sign-in reply had already expired. Check your Mac's clock and try again."
            case .wrongNonce: "The sign-in reply didn't match this sign-in. Try again."
            }
        }
    }

    /// Checks the signature against OpenAI's keys, then the issuer, audience, expiry and nonce.
    static func validate(_ token: String, keys: [JWK], clientID: String, nonce: String?, now: Date = .now) throws -> IDTokenClaims {
        guard let jwt = try? JWT(token) else { throw Problem.malformed }
        guard jwt.header["alg"]?.string == "RS256" else { throw Problem.unsupportedAlgorithm }
        let kid = jwt.header["kid"]?.string
        let candidates = keys.filter { $0.kty == "RSA" && (kid == nil || $0.kid == kid) }
        guard !candidates.isEmpty else { throw Problem.unknownKey }
        guard candidates.contains(where: { verify(jwt, with: $0) }) else { throw Problem.badSignature }

        let c = jwt.claims
        guard c["iss"]?.string == OpenAIAuthConfig.issuer else { throw Problem.wrongIssuer }
        let audiences = c["aud"]?.array?.compactMap(\.string) ?? c["aud"]?.string.map { [$0] } ?? []
        guard audiences.contains(clientID) else { throw Problem.wrongAudience }
        guard let exp = c["exp"]?.double, Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-120) else { throw Problem.expired }
        if let nonce { guard let got = c["nonce"]?.string, constantTimeEquals(got, nonce) else { throw Problem.wrongNonce } }
        guard let sub = c["sub"]?.string, !sub.isEmpty else { throw Problem.noSubject }
        return IDTokenClaims(sub: sub, email: c["email"]?.string, name: c["name"]?.string, picture: c["picture"]?.string)
    }

    static func verify(_ jwt: JWT, with jwk: JWK) -> Bool {
        guard let n = jwk.n.flatMap(Base64URL.decode), let e = jwk.e.flatMap(Base64URL.decode),
              let key = publicKey(modulus: n, exponent: e) else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, jwt.signingInput as CFData, jwt.signature as CFData, &error)
    }

    /// Builds an RSA public key from a JWK's modulus and exponent (PKCS#1 RSAPublicKey, DER).
    static func publicKey(modulus: Data, exponent: Data) -> SecKey? {
        func integer(_ bytes: Data) -> Data {
            var b = [UInt8](bytes.drop(while: { $0 == 0 }))
            if b.isEmpty { b = [0] }
            if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
            return Data([0x02]) + length(b.count) + Data(b)
        }
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var n = count, bytes: [UInt8] = []
            while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.drop(while: { $0 == 0 }).count * 8,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

// MARK: - Loopback HTTP

enum LoopbackHTTP {
    struct Request: Equatable {
        let method: String
        let path: String
        let query: [String: String]
    }

    /// Reads the request line of an HTTP request head, e.g. "GET /auth/callback?code=…&state=… HTTP/1.1".
    static func parse(_ head: String) -> Request? {
        guard let line = head.components(separatedBy: "\r\n").first ?? head.components(separatedBy: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[2].hasPrefix("HTTP/") else { return nil }
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return nil }
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return Request(method: String(parts[0]), path: String(pieces[0]), query: pieces.count > 1 ? FormEncoding.decode(String(pieces[1])) : [:])
    }

    static func response(status: Int, title: String, message: String) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Stringline</title>
        <style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#F3F3F1;color:#17181A;font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}
        main{max-width:420px;margin:24px;padding:28px 30px;background:#fff;border:1px solid #E3E3DF;border-radius:16px}
        h1{margin:0 0 6px;font-size:22px}p{margin:0;color:#565961}.bar{width:44px;height:6px;border-radius:3px;background:#FFC21A;margin-bottom:18px}</style></head>
        <body><main><div class="bar"></div><h1>\(esc(title))</h1><p>\(esc(message))</p></main></body></html>
        """
        let body = Data(html.utf8)
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
