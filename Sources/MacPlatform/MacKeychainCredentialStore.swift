import Foundation
import Security
import LauncherCore

/// Keychain-backed refresh-token storage. Only the refresh token is persisted.
public struct MacKeychainCredentialStore: RefreshTokenStoring {
    public static let defaultService = "com.lingxifox.LingXiLauncher.microsoft"
    private let service: String

    public init(service: String = MacKeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func save(refreshToken: String, for accountID: UUID) throws {
        let data = Data(refreshToken.utf8)
        var query = baseQuery(accountID: accountID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus, action: "update") }
        query.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus, action: "add") }
    }

    public func loadRefreshToken(for accountID: UUID) throws -> String? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status, action: "read") }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw LauncherError(.keychainFailure, "Keychain entry for account \(accountID.uuidString) is empty or unreadable")
        }
        return token
    }

    public func deleteRefreshToken(for accountID: UUID) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, action: "delete")
        }
    }

    private func baseQuery(accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString.lowercased(),
        ]
    }

    private func keychainError(_ status: OSStatus, action: String) -> LauncherError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return LauncherError(.keychainFailure, "Keychain \(action) failed: \(message)",
            suggestion: "Unlock the login keychain and retry; the launcher never writes tokens to plain files.")
    }
}
