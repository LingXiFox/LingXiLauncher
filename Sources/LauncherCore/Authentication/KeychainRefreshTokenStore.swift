import Foundation

/// Secure storage for the long-lived OAuth refresh token.
///
/// Only the refresh token is persisted. Minecraft/Xbox access tokens live in memory for the
/// lifetime of the process and are refreshed instead of being written to disk.
public protocol RefreshTokenStoring: Sendable {
    func save(refreshToken: String, for accountID: UUID) throws
    func loadRefreshToken(for accountID: UUID) throws -> String?
    func deleteRefreshToken(for accountID: UUID) throws
}

/// Test double. Stores tokens in memory only.
public final class InMemoryRefreshTokenStore: RefreshTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    public init() {}

    public func save(refreshToken: String, for accountID: UUID) throws {
        lock.lock()
        tokens[accountID] = refreshToken
        lock.unlock()
    }

    public func loadRefreshToken(for accountID: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[accountID]
    }

    public func deleteRefreshToken(for accountID: UUID) throws {
        lock.lock()
        tokens.removeValue(forKey: accountID)
        lock.unlock()
    }
}
