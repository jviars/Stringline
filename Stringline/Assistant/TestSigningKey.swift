#if DEBUG || STRINGLINE_TESTS
import Foundation
import Security

/// A throwaway RSA key for tests only: signs fake ID tokens and publishes the matching JWK,
/// so the sign-in checks can be exercised without OpenAI.
struct TestSigningKey {
    let privateKey: SecKey
    let kid: String

    init(kid: String = "stringline-test-key") {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        self.kid = kid
    }

    /// The public half as a JWK, read from the PKCS#1 RSAPublicKey DER (SEQUENCE { n, e }).
    var jwk: JWK {
        let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data)
        var i = 0
        func length() -> Int {
            let first = Int(der[i]); i += 1
            guard first & 0x80 != 0 else { return first }
            var n = 0
            for _ in 0..<(first & 0x7F) { n = n << 8 | Int(der[i]); i += 1 }
            return n
        }
        func integer() -> Data {
            precondition(der[i] == 0x02); i += 1
            let count = length()
            defer { i += count }
            return Data(der[i..<(i + count)])
        }
        precondition(der[i] == 0x30); i += 1
        _ = length()
        let n = integer(), e = integer()
        return JWK(kty: "RSA", kid: kid, n: Base64URL.encode(n), e: Base64URL.encode(e), alg: "RS256", use: "sig")
    }

    func sign(_ claims: JSONValue, alg: String = "RS256", kid: String? = nil) -> String {
        let header: JSONValue = ["alg": .string(alg), "typ": "JWT", "kid": .string(kid ?? self.kid)]
        let input = "\(Base64URL.encode(header.data)).\(Base64URL.encode(claims.data))"
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
        return "\(input).\(Base64URL.encode(signature))"
    }
}
#endif
