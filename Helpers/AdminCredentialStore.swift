/// On-device, encrypted storage for the admin credential used by privileged
/// actions. Backed by the macOS Keychain with a "this device only" access
/// class, so the value:
///   • never syncs to iCloud Keychain or any other device,
///   • is never included in encrypted backups,
///   • is only readable while the Mac is unlocked, and
///   • is only ever read back locally to prime `sudo` — never transmitted.
/// The store exists so the user authenticates once, ever, instead of once per
/// launch. If the stored password stops working (e.g. the login password
/// changed), the caller clears it and prompts again.

import Foundation
import Security

/// A minimal Keychain wrapper for the single admin-credential item.
///
/// ```swift
/// AdminCredentialStore.save("password")
/// let pass = AdminCredentialStore.load()
/// ```
enum AdminCredentialStore {
    /// Service identifier for the Keychain item (scoped to this app).
    private static let service = "com.catalyst.app.adminCredential"

    /// Account key. Tied to the current user so a shared machine keeps
    /// per-account credentials separate.
    private static var account: String {
        NSUserName()
    }

    /// Persists the admin password on-device. Overwrites any existing item.
    @discardableResult
    /// - Parameter password: The unencrypted token required for system access.
    /// - Returns: True if standard keychain routines confirm write completion.
    static func save(_ password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        // Remove any prior item first so `add` never collides.
        clear()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // On-device only, readable solely while unlocked.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the stored admin password, or `nil` if none is saved.
    /// - Returns: The unencrypted token required for system access, if present.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// Deletes the stored admin password. No-op if none exists.
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
