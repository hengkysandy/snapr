import CryptoKit
import Foundation
import Security

/// Errors from the Keychain layer.
///
/// Every one of these is thrown rather than swallowed. That is the whole point
/// of this file: see the comment on `loadOrCreateKey`.
enum KeyStoreError: Error, CustomStringConvertible {
    /// The Keychain returned a status we did not expect. The library key may
    /// exist and be unreadable, so we must not carry on.
    case keychainFailed(OSStatus)
    /// An item exists but its data is not a 256-bit key.
    case wrongKeySize(Int)
    /// An item exists but the Keychain gave us no data back for it.
    case itemHasNoData

    var description: String {
        switch self {
        case .keychainFailed(let status):
            return "Keychain error \(status)"
        case .wrongKeySize(let n):
            return "Keychain item is \(n) bytes, expected 32"
        case .itemHasNoData:
            return "Keychain item exists but returned no data"
        }
    }
}

/// The one 256-bit key. It keys SQLCipher (`PRAGMA key`) and every AES-GCM
/// sealed blob.
///
/// The service name is a locked decision. Changing it is destructive: the app
/// would find no key, generate a fresh one, and the whole encrypted library
/// would become permanently unreadable.
enum KeyStore {
    static let service = "com.hengkysandy.snapr.dbkey"

    /// One key per service. The account name never changes, so there is exactly
    /// one item and no way to pick the wrong one.
    private static let account = "primary"

    /// Expected key length in bytes. CryptoKit `SymmetricKey(size: .bits256)`.
    private static let keyBytes = 32

    /// Loads the library key, generating it only on the **first** launch.
    ///
    /// The rule that matters more than anything else in this file: if an item
    /// exists but cannot be read, this THROWS. It must never fall back to
    /// generating a fresh key. A fresh key does not fail loudly, it succeeds
    /// quietly against a library it cannot decrypt, and every existing capture
    /// becomes permanently unreadable. A thrown error is recoverable. A
    /// silently replaced key is not.
    ///
    /// The `service` parameter exists so tests can use a throwaway service name
    /// and never touch the real key. Callers in the app use the default.
    static func loadOrCreateKey(service: String = KeyStore.service) throws -> SymmetricKey {
        if let existing = try readKey(service: service) {
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        try store(fresh, service: service)
        return fresh
    }

    /// Removes the key. Used only by tests, against a throwaway service name.
    ///
    /// `errSecItemNotFound` is not an error here: "there is no key" is exactly
    /// the state the caller asked for.
    static func deleteKey(service: String = KeyStore.service) throws {
        // `Any` here is the Security framework's CFDictionary bridge, not a
        // Swift existential. SecItem takes no other shape.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychainFailed(status)
        }
    }

    // MARK: - Private

    /// Returns the stored key, or nil only when there is genuinely no item.
    /// Any other failure throws, because "cannot read" and "does not exist" have
    /// opposite consequences and must never be collapsed into one answer.
    private static func readKey(service: String) throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = item as? Data else { throw KeyStoreError.itemHasNoData }
            guard data.count == keyBytes else {
                throw KeyStoreError.wrongKeySize(data.count)
            }
            return SymmetricKey(data: data)
        default:
            // Locked keychain, denied access, damaged item: all of these mean a
            // key may exist. Throw.
            throw KeyStoreError.keychainFailed(status)
        }
    }

    private static func store(_ key: SymmetricKey, service: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Never leaves this Mac and never syncs to iCloud Keychain. The
            // library it decrypts is local-only, so a synced key would widen
            // the blast radius for no benefit. `AfterFirstUnlock` rather than
            // `WhenUnlocked` because the background OCR worker keeps running
            // while the screen is locked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainFailed(status)
        }
    }
}
