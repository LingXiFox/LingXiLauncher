import Foundation

/// Where a shader pack came from. `modrinth` records are eligible for update checks; imported
/// archives stay `local` and are never guessed to be a Modrinth project.
public enum ShaderPackSource: String, Codable, Sendable, Equatable {
    case modrinth
    case local
}

/// A shader pack installed in the instance-local `shaderpacks/` directory.
///
/// The archive remains the single source of truth. Records only describe verified provenance;
/// a missing file is removed from the list, and a hash mismatch disables activation.
public struct InstalledShaderPack: Codable, Sendable, Equatable, Identifiable {
    public var projectID: String?
    public var slug: String?
    public var title: String
    public var versionID: String?
    public var versionNumber: String?
    public var fileName: String
    public var sha1: String?
    public var sha512: String?
    public var fileSize: Int
    public var source: ShaderPackSource
    public var license: String?
    public var iconURL: String?
    public var installedAt: Date

    public var id: String { projectID ?? sha1 ?? fileName }

    public init(
        projectID: String? = nil,
        slug: String? = nil,
        title: String,
        versionID: String? = nil,
        versionNumber: String? = nil,
        fileName: String,
        sha1: String? = nil,
        sha512: String? = nil,
        fileSize: Int,
        source: ShaderPackSource = .local,
        license: String? = nil,
        iconURL: String? = nil,
        installedAt: Date = Date()
    ) {
        self.projectID = projectID
        self.slug = slug
        self.title = title
        self.versionID = versionID
        self.versionNumber = versionNumber
        self.fileName = fileName
        self.sha1 = sha1
        self.sha512 = sha512
        self.fileSize = fileSize
        self.source = source
        self.license = license
        self.iconURL = iconURL
        self.installedAt = installedAt
    }
}

public struct ShaderPackUpdate: Sendable, Equatable {
    public let projectID: String
    public let title: String
    public let currentVersionID: String?
    public let currentVersionNumber: String?
    public let latestVersionID: String
    public let latestVersionNumber: String
    public let latestFile: ModrinthFile
    public let license: String?
    public let iconURL: String?

    public init(
        projectID: String,
        title: String,
        currentVersionID: String?,
        currentVersionNumber: String?,
        latestVersionID: String,
        latestVersionNumber: String,
        latestFile: ModrinthFile,
        license: String?,
        iconURL: String?
    ) {
        self.projectID = projectID
        self.title = title
        self.currentVersionID = currentVersionID
        self.currentVersionNumber = currentVersionNumber
        self.latestVersionID = latestVersionID
        self.latestVersionNumber = latestVersionNumber
        self.latestFile = latestFile
        self.license = license
        self.iconURL = iconURL
    }
}

public enum ShaderPackPhase: String, Sendable, Equatable {
    case resolving
    case downloading
    case verifying
    case committing
    case done
}

public struct ShaderPackProgress: Sendable, Equatable {
    public let phase: ShaderPackPhase
    public let message: String
    public let completed: Int
    public let total: Int
    public let currentFile: String?

    public init(
        phase: ShaderPackPhase,
        message: String,
        completed: Int,
        total: Int,
        currentFile: String? = nil
    ) {
        self.phase = phase
        self.message = message
        self.completed = completed
        self.total = total
        self.currentFile = currentFile
    }
}

public struct ShaderPackInstallReport: Sendable, Equatable {
    public let installed: InstalledShaderPack
    public let downloadedBytes: Int
    public let downloadedFiles: Int
    public let alreadyInstalled: Bool

    public init(
        installed: InstalledShaderPack,
        downloadedBytes: Int,
        downloadedFiles: Int,
        alreadyInstalled: Bool = false
    ) {
        self.installed = installed
        self.downloadedBytes = downloadedBytes
        self.downloadedFiles = downloadedFiles
        self.alreadyInstalled = alreadyInstalled
    }
}

public struct ShaderCompatibility: Sendable, Equatable {
    public let instanceID: String
    public let versionID: String
    public let gameVersion: String
    public let loader: ModLoaderKind
    public let loaderVersion: String?

    public init(
        instanceID: String,
        versionID: String,
        gameVersion: String,
        loader: ModLoaderKind,
        loaderVersion: String?
    ) {
        self.instanceID = instanceID
        self.versionID = versionID
        self.gameVersion = gameVersion
        self.loader = loader
        self.loaderVersion = loaderVersion
    }
}

/// The subset of Iris' `config/iris.properties` that this launcher can safely inspect.
public struct ShaderActivationState: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case enabled
        case disabled
        case notConfigured
        case notInstalled
        case unsupported
    }

    public let kind: Kind
    public let shaderPack: String?
    public let configURL: URL?
    public let message: String

    public init(kind: Kind, shaderPack: String?, configURL: URL?, message: String) {
        self.kind = kind
        self.shaderPack = shaderPack
        self.configURL = configURL
        self.message = message
    }
}

public struct ShaderActivationResult: Sendable, Equatable {
    public let configURL: URL
    public let backupURL: URL?
    public let shaderPack: String
    public let message: String

    public init(configURL: URL, backupURL: URL?, shaderPack: String, message: String) {
        self.configURL = configURL
        self.backupURL = backupURL
        self.shaderPack = shaderPack
        self.message = message
    }
}
