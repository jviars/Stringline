import Foundation
import Security
import LocalAuthentication

/// Where sign-in tokens and API keys live. Never in PavingData, never synced.
protocol SecretStore: AnyObject {
    func read(_ account: String) -> Data?
    func write(_ data: Data, for account: String) throws
    func delete(_ account: String)
}

extension SecretStore {
    func readJSON<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        read(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func writeJSON<T: Encodable>(_ value: T, for account: String) throws {
        try write(JSONEncoder().encode(value), for: account)
    }
}

/// The login keychain on this Mac. Items are marked not to sync to iCloud Keychain.
///
/// Stringline is signed "to run locally", so each rebuild or update looks like a different app to the keychain, and
/// reading an item an older build made asks for the login password. The read waits on that prompt, which once froze
/// the app at launch. So each slot remembers which build made it: a different build never reads it and starts a fresh
/// slot instead. The person just signs in again. (With a Developer ID signature the build stays the same across updates.)
final class KeychainStore: SecretStore {
    let service: String
    private let generationKey: String
    private let ownerKey: String

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "The Keychain couldn't save it (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))."
        }
    }

    init(service: String = "app.stringline.Stringline.assistant") {
        self.service = service
        generationKey = "\(service).generation"
        ownerKey = "\(service).owner"
    }

    /// This build's designated requirement: what the keychain checks before handing over an item's data.
    static let thisBuild: String = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return "unsigned" }
        return text as String
    }()

    /// True when this build made the current slot, so reading it can't prompt.
    private var ownsSlot: Bool { UserDefaults.standard.string(forKey: ownerKey) == Self.thisBuild }

    private func claimFreshSlot() {
        generation += 1
        UserDefaults.standard.set(Self.thisBuild, forKey: ownerKey)
    }

    private var generation: Int {
        get { UserDefaults.standard.integer(forKey: generationKey) }
        set { UserDefaults.standard.set(newValue, forKey: generationKey) }
    }

    private func name(_ account: String) -> String { generation == 0 ? account : "\(account).\(generation)" }

    private func query(_ account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: name(account),
                kSecUseAuthenticationContext as String: context,
                // kSecUseAuthenticationUI = kSecUseAuthenticationUIFail: never show a keychain prompt.
                "u_AuthUI": "u_AuthUIF"]
    }

    private static let blocked: Set<OSStatus> = [errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem]

    func read(_ account: String) -> Data? {
        guard ownsSlot else { return nil }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data, for account: String) throws {
        if !ownsSlot { claimFreshSlot() }
        var status = attemptWrite(data, account)
        if Self.blocked.contains(status) {
            // An earlier build's item is in the way: use a new slot instead of asking for the password.
            generation += 1
            status = attemptWrite(data, account)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private func attemptWrite(_ data: Data, _ account: String) -> OSStatus {
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add.removeValue(forKey: kSecUseAuthenticationContext as String)
            add.removeValue(forKey: "u_AuthUI")
            add[kSecValueData as String] = data
            add[kSecAttrSynchronizable as String] = false
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "Stringline assistant (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    func delete(_ account: String) {
        // Another build's items are left alone: touching them could ask for the password too.
        guard ownsSlot else { return }
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// For the self-test: nothing leaves memory.
final class MemorySecretStore: SecretStore {
    private var items: [String: Data] = [:]
    func read(_ account: String) -> Data? { items[account] }
    func write(_ data: Data, for account: String) throws { items[account] = data }
    func delete(_ account: String) { items[account] = nil }
}
