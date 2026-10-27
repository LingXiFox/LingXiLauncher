import Foundation

/// Persists non-secret Microsoft account metadata under `<dataRoot>/accounts/microsoft/`.
/// Tokens are never written here (they live in the Keychain).
public struct MicrosoftAccountStore: Sendable {
    private let layout: GameDataLayout

    public init(layout: GameDataLayout) {
        self.layout = layout
    }

    public var directory: URL {
        layout.accountsDirectory.appendingPathComponent("microsoft", isDirectory: true)
    }

    public func list() throws -> [MicrosoftAccount] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            try decode(try Data(contentsOf: url), url: url)
        }
    }

    public func load(id: UUID) throws -> MicrosoftAccount {
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LauncherError(
                .missingDependency,
                "Microsoft account \(id.uuidString) is not stored locally",
                suggestion: "Sign in with Microsoft again."
            )
        }
        return try decode(try Data(contentsOf: url), url: url)
    }

    public func save(_ account: MicrosoftAccount) throws {
        let url = fileURL(id: account.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(account).write(to: url, options: [.atomic])
        } catch {
            throw LauncherError(.ioFailure, "Cannot write Microsoft account metadata \(url.path): \(error.localizedDescription)")
        }
    }

    public func delete(id: UUID) throws {
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw LauncherError(.ioFailure, "Cannot delete Microsoft account metadata \(url.path): \(error.localizedDescription)")
        }
    }

    private func fileURL(id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).json", isDirectory: false)
    }

    private func decode(_ data: Data, url: URL) throws -> MicrosoftAccount {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(MicrosoftAccount.self, from: data)
        } catch {
            throw LauncherError(.invalidMetadata, "Corrupted Microsoft account file \(url.path): \(error.localizedDescription)")
        }
    }
}

/// Identity selection shared by CLI and GUI. References only, no credentials.
public struct AccountReference: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case microsoft
        case local
    }

    public let kind: Kind
    public let identifier: String

    public init(kind: Kind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    public var storageKey: String { "\(kind.rawValue):\(identifier)" }
}

public struct ActiveAccountStore: Sendable {
    private let layout: GameDataLayout

    public init(layout: GameDataLayout) {
        self.layout = layout
    }

    private var fileURL: URL {
        layout.accountsDirectory.appendingPathComponent("active.json", isDirectory: false)
    }

    public func load() -> AccountReference? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AccountReference.self, from: data)
    }

    public func save(_ reference: AccountReference?) throws {
        do {
            try FileManager.default.createDirectory(at: layout.accountsDirectory, withIntermediateDirectories: true)
            if let reference {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(reference).write(to: fileURL, options: [.atomic])
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            throw LauncherError(.ioFailure, "Cannot save the active account: \(error.localizedDescription)")
        }
    }
}
