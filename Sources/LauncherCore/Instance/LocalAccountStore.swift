import Foundation

/// A persisted `LocalOffline` account.
///
/// The record is intentionally explicit about being unverified and contains no token field at
/// all: there is nothing that could be mistaken for a Microsoft/Minecraft Services session.
public struct LocalOfflineAccount: Codable, Sendable, Equatable {
    public let playerName: String
    public let offlineUUID: UUID
    public let identityMode: IdentityMode
    public let createdAt: Date
    /// Always `true`. Kept in the file so a human reading it cannot misread the identity.
    public let unverified: Bool

    public init(playerName: String, offlineUUID: UUID, createdAt: Date = Date()) {
        self.playerName = playerName
        self.offlineUUID = offlineUUID
        self.identityMode = .localOffline
        self.createdAt = createdAt
        self.unverified = true
    }

    public var profile: LocalOfflineProfile {
        LocalOfflineProfile(playerName: playerName, stableOfflineUUID: offlineUUID)
    }
}

/// Stores local offline accounts under `<dataRoot>/accounts/local/<name>.json`.
public struct LocalAccountStore: Sendable {
    public let layout: GameDataLayout

    public init(layout: GameDataLayout) {
        self.layout = layout
    }

    /// Creates the account, or returns the existing one when the name was already created.
    /// The UUID is derived from the name, so re-creating can never rotate it silently.
    @discardableResult
    public func create(playerName: String) throws -> LocalOfflineAccount {
        let name = try LocalOfflineIdentity.validatedName(playerName)
        if let existing = try? load(playerName: name) {
            return existing
        }
        let account = LocalOfflineAccount(playerName: name, offlineUUID: LocalOfflineIdentity.offlineUUID(forName: name))
        try write(account)
        return account
    }

    public func load(playerName: String) throws -> LocalOfflineAccount {
        let name = try LocalOfflineIdentity.validatedName(playerName)
        let url = try accountURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LauncherError(
                .missingDependency,
                "Local offline account '\(name)' does not exist",
                suggestion: "Create it first: lingxi account local create --name \(name)"
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(url.path): \(error.localizedDescription)")
        }
        return try decode(data, url: url)
    }

    public func list() throws -> [LocalOfflineAccount] {
        let directory = layout.localAccountsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            try decode(Data(contentsOf: url), url: url)
        }
    }

    public func profile(forName playerName: String) throws -> LocalOfflineProfile {
        let account = try load(playerName: playerName)
        return account.profile
    }

    // MARK: - Persistence

    private func accountURL(_ playerName: String) throws -> URL {
        let file = try PathSafety.validatedPathComponent(playerName) + ".json"
        return layout.localAccountsDirectory.appendingPathComponent(file, isDirectory: false)
    }

    private func write(_ account: LocalOfflineAccount) throws {
        let url = try accountURL(account.playerName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: layout.localAccountsDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(account)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw LauncherError(.ioFailure, "Cannot write local account \(url.path): \(error.localizedDescription)")
        }
    }

    private func decode(_ data: Data, url: URL) throws -> LocalOfflineAccount {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let account = try decoder.decode(LocalOfflineAccount.self, from: data)
            guard account.identityMode == .localOffline else {
                throw LauncherError(.identityIsolationViolation, "\(url.lastPathComponent) is not a local offline account")
            }
            return account
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError(.invalidMetadata, "Corrupted local account file \(url.path): \(error.localizedDescription)")
        }
    }
}
