import Foundation
import Security

/// Where credentials are kept. The real one is the macOS Keychain; tests use
/// `MemoryKeychain` and never touch it.
public protocol KeychainStore: Sendable {
    /// Whether secrets can be stored at all.
    var available: Bool { get }
    func read(service: String, account: String) -> String?
    /// Stores or replaces the secret. False when the Keychain refused.
    func write(service: String, account: String, secret: String) -> Bool
    /// Removes the secret. True when it is gone afterwards, including when it was never there.
    func delete(service: String, account: String) -> Bool
}

/// Generic-password items in the login Keychain.
public final class SystemKeychain: KeychainStore {
    public init() {}

    public var available: Bool { true }

    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(service: String, account: String) -> String? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(service: String, account: String, secret: String) -> Bool {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(service, account)
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// A keychain that lives in memory, for tests.
public final class MemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var isAvailable: Bool

    public init(available: Bool = true) { isAvailable = available }

    public var available: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isAvailable }
        set { lock.lock(); isAvailable = newValue; lock.unlock() }
    }

    public func read(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items["\(service)\u{0}\(account)"]
    }

    public func write(service: String, account: String, secret: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isAvailable else { return false }
        items["\(service)\u{0}\(account)"] = secret
        return true
    }

    public func delete(service: String, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items["\(service)\u{0}\(account)"] = nil
        return true
    }
}

/// Credential storage.
///
/// Keys live in the macOS Keychain, so they are only readable by this app on
/// this machine and user. We never ship a shared provider key: the user
/// supplies their own.
public final class Secrets: Sendable {
    private static let apiKey = "anthropic_api_key"
    private static let jevKey = "typesafe_api_key"

    private let keychain: KeychainStore
    private let service: String
    private let environment: @Sendable () -> [String: String]

    public init(service: String, keychain: KeychainStore = SystemKeychain(), environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }) {
        self.service = service
        self.keychain = keychain
        self.environment = environment
    }

    public var available: Bool { keychain.available }

    private func set(_ slot: String, _ key: String) -> Bool {
        let trimmed = key.jsTrimmed
        if trimmed.isEmpty {
            _ = keychain.delete(service: service, account: slot)
            return true
        }
        if !available { return false }
        return keychain.write(service: service, account: slot, secret: trimmed)
    }

    private func get(_ slot: String, _ envVar: String) -> String? {
        let fallback = environment()[envVar]
        // A value that cannot be read is treated as absent rather than crashing at startup.
        guard available, let stored = keychain.read(service: service, account: slot), !stored.isEmpty else { return fallback }
        return stored
    }

    /// Anthropic, for the planning model.
    @discardableResult
    public func setApiKey(_ key: String) -> Bool { set(Secrets.apiKey, key) }
    public func getApiKey() -> String? { get(Secrets.apiKey, "ANTHROPIC_API_KEY") }
    public func hasApiKey() -> Bool { !(getApiKey() ?? "").isEmpty }

    /// TypeSafe AI, for Jev. A separate provider needs a separate credential.
    @discardableResult
    public func setJevKey(_ key: String) -> Bool { set(Secrets.jevKey, key) }
    public func getJevKey() -> String? { get(Secrets.jevKey, "TYPESAFE_API_KEY") }
    public func hasJevKey() -> Bool { !(getJevKey() ?? "").isEmpty }
}
