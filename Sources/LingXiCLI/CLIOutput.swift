import Foundation
import LauncherCore

/// Process exit codes. Launcher-level failures use sysexits-style values so they cannot be
/// confused with a (0-255) exit code returned by the game itself, which is passed through when
/// the game runs to completion.
enum ExitStatus: Int32 {
    case success = 0
    case javaUnusable = 3
    case preflightBlocked = 4
    case usage = 64
    case dataError = 65
    case missingInput = 66
    case unavailable = 69
    case internalError = 70
    case ioError = 74
}

// MARK: - JSON output models

struct JSONPlatform: Encodable {
    let os: String
    let architecture: String
    let version: String
}

struct JSONJavaRuntime: Encodable {
    let path: String
    let version: String?
    let majorVersion: Int?
    let architecture: String?
    let vendor: String?
    let usable: Bool
    let error: String?
}

struct JSONDiagnostic: Encodable {
    let severity: String
    let code: String?
    let message: String
    let suggestion: String?

    init(_ diagnostic: LaunchDiagnostic) {
        self.severity = diagnostic.severity.rawValue
        self.code = diagnostic.code?.rawValue
        self.message = diagnostic.message
        self.suggestion = diagnostic.suggestion
    }
}

struct JSONMissingDependency: Encodable {
    let kind: String
    let path: String
    let reason: String
    let url: String?
    let sha1: String?
    let size: Int?

    init(_ missing: MissingDependency) {
        self.kind = missing.kind.rawValue
        self.path = missing.path.path
        self.reason = missing.reason.rawValue
        self.url = missing.downloadURL?.absoluteString
        self.sha1 = missing.sha1
        self.size = missing.size
    }
}

struct JSONInspect: Encodable {
    let versionID: String
    let type: String
    let mainClass: String
    let format: String
    let javaComponent: String?
    let javaMajorVersion: Int?
    let libraryCount: Int
    let allowedLibraryCount: Int
    let classpathEntryCount: Int
    let legacyNativeCount: Int
    let jvmArgumentCount: Int
    let gameArgumentCount: Int
    let assetIndexID: String
    let clientJarSHA1: String?
    let clientJarSize: Int?
    let inheritsFrom: String?
    let metadataPath: String
    let missing: [JSONMissingDependency]
    let diagnostics: [JSONDiagnostic]
}

struct JSONDoctor: Encodable {
    let platform: JSONPlatform
    let gameRoot: String
    let dataRoot: String
    let javaCandidates: [JSONJavaRuntime]
    let selectedJava: JSONJavaRuntime?
    let versionID: String?
    let missing: [JSONMissingDependency]
    let diagnostics: [JSONDiagnostic]
    let ok: Bool
}

struct JSONPreview: Encodable {
    let dryRun: Bool
    let identityMode: String
    let identity: String
    let versionID: String
    let javaExecutable: String
    let mainClass: String
    let classpathEntryCount: Int
    let classpathEntries: [String]
    let gameDirectory: String
    let jvmArguments: [String]
    let gameArguments: [String]
    let missingDependencies: [JSONMissingDependency]
    let diagnostics: [JSONDiagnostic]
    let blocking: Bool
}

struct JSONAccount: Encodable {
    let playerName: String
    let offlineUUID: String
    let identityMode: String
    let unverified: Bool
    let createdAt: String
}

struct JSONInstance: Encodable {
    let id: String
    let displayName: String
    let versionID: String?
    let directory: String
    let gameDirectory: String
    let createdAt: String
    let lastLaunchedAt: String?
    let lastIdentityMode: String?
}

struct JSONVersionEntry: Encodable {
    let id: String
    let type: String
    let releaseTime: String?
    let url: String?
    let sha1: String?

    init(_ entry: VersionManifest.Entry) {
        self.id = entry.id
        self.type = entry.type.rawValue
        self.releaseTime = entry.releaseTime
        self.url = entry.urlString
        self.sha1 = entry.sha1
    }
}

struct JSONVersionList: Encodable {
    let source: String
    let count: Int
    let versions: [JSONVersionEntry]
}

struct JSONInstallReport: Encodable {
    let versionID: String
    let instanceID: String
    let gameDirectory: String
    let downloadedFiles: Int
    let downloadedBytes: Int
    let cacheHits: Int
    let assetObjectCount: Int
    let extractedNatives: Int
    let missingAfterInstall: [JSONMissingDependency]
    let diagnostics: [JSONDiagnostic]
    let javaMajorVersion: Int?
    let javaComponent: String?
    let sourcePolicy: String
    let complete: Bool

    init(_ report: InstallReport) {
        self.versionID = report.versionID
        self.instanceID = report.instanceID
        self.gameDirectory = report.gameDirectory.path
        self.downloadedFiles = report.downloadedFiles
        self.downloadedBytes = report.downloadedBytes
        self.cacheHits = report.cacheHits
        self.assetObjectCount = report.assetObjectCount
        self.extractedNatives = report.extractedNatives
        self.missingAfterInstall = report.missingAfterInstall.map(JSONMissingDependency.init)
        self.diagnostics = report.diagnostics.map(JSONDiagnostic.init)
        self.javaMajorVersion = report.javaRequirement.majorVersion
        self.javaComponent = report.javaRequirement.component
        self.sourcePolicy = report.sourcePolicy.rawValue
        self.complete = report.isComplete
    }
}

struct JSONVerificationIssue: Encodable {
    let kind: String
    let path: String
    let expected: String?
    let actual: String?

    init(_ issue: VerificationIssue) {
        self.kind = issue.kind.rawValue
        self.path = issue.path.path
        self.expected = issue.expected
        self.actual = issue.actual
    }
}

struct JSONVerifyReport: Encodable {
    let versionID: String
    let checkedFiles: Int
    let checkedBytes: Int
    let clean: Bool
    let missingCount: Int
    let mismatchCount: Int
    let issues: [JSONVerificationIssue]

    init(_ report: VerificationReport) {
        self.versionID = report.versionID
        self.checkedFiles = report.checkedFiles
        self.checkedBytes = report.checkedBytes
        self.clean = report.isClean
        self.missingCount = report.missingCount
        self.mismatchCount = report.mismatchCount
        self.issues = report.issues.map(JSONVerificationIssue.init)
    }
}

struct JSONMessage: Encodable {
    let ok: Bool
    let message: String
    let code: String?
}

// MARK: - Output

enum CLIOutput {
    static func emitJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fail("Cannot encode JSON output: \(error.localizedDescription)")
        }
    }

    static func fail(_ message: String) {
        // Keep stdout/stderr ordering sane when both are redirected to the same terminal/file.
        fflush(stdout)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func fail(_ error: LauncherError) {
        fail("error: \(error.description)")
    }

    static func header(_ title: String) {
        print(title)
        print(String(repeating: "-", count: max(3, title.count)))
    }

    static func field(_ label: String, _ value: String, indent: Int = 2) {
        let padding = String(repeating: " ", count: indent)
        print("\(padding)\(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(value)")
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func printDiagnostics(_ diagnostics: [LaunchDiagnostic]) {
        guard !diagnostics.isEmpty else { return }
        print("Diagnostics:")
        for diagnostic in diagnostics {
            print("  - \(diagnostic.description)")
        }
    }

    static func printMissing(_ missing: [MissingDependency], limit: Int = 12) {
        guard !missing.isEmpty else { return }
        print("Missing files (\(missing.count)):")
        for item in missing.prefix(limit) {
            print("  - \(item.kind.rawValue): \(item.path.path) [\(item.reason.rawValue)]")
        }
        if missing.count > limit {
            print("  … and \(missing.count - limit) more")
        }
    }

    static func jsonRuntime(_ runtime: JavaRuntime) -> JSONJavaRuntime {
        JSONJavaRuntime(
            path: runtime.executable.path,
            version: runtime.versionString,
            majorVersion: runtime.majorVersion,
            architecture: runtime.architecture.rawValue,
            vendor: runtime.vendor,
            usable: true,
            error: nil
        )
    }

    static func jsonJavaFailure(path: URL, error: Error) -> JSONJavaRuntime {
        JSONJavaRuntime(
            path: path.path,
            version: nil,
            majorVersion: nil,
            architecture: nil,
            vendor: nil,
            usable: false,
            error: (error as? LauncherError)?.description ?? error.localizedDescription
        )
    }
}
