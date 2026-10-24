import Foundation

/// A launcher error with a stable machine-readable code and an actionable suggestion.
///
/// Deliberately a value type with no associated payload that could carry a session token:
/// `description` is safe to print, log and serialize.
public struct LauncherError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable, Codable, CaseIterable {
        case invalidMetadata = "INVALID_METADATA"
        case unsupportedVersion = "UNSUPPORTED_VERSION"
        case missingDependency = "MISSING_DEPENDENCY"
        case javaNotFound = "JAVA_NOT_FOUND"
        case javaVersionMismatch = "JAVA_VERSION_MISMATCH"
        case javaArchitectureMismatch = "JAVA_ARCH_MISMATCH"
        case unauthorized = "UNAUTHORIZED"
        case appRegistrationRejected = "APP_REGISTRATION_REJECTED"
        case launchFailed = "LAUNCH_FAILED"
        case invalidProfileName = "INVALID_PROFILE_NAME"
        case identityIsolationViolation = "IDENTITY_ISOLATION_VIOLATION"
        case ioFailure = "IO_FAILURE"
        case pathEscapesRoot = "PATH_ESCAPES_ROOT"
        case usageError = "USAGE_ERROR"
        case notImplemented = "NOT_IMPLEMENTED"
    }

    public let code: Code
    public let message: String
    public let suggestion: String?

    public init(_ code: Code, _ message: String, suggestion: String? = nil) {
        self.code = code
        self.message = message
        self.suggestion = suggestion
    }

    public var description: String {
        if let suggestion, !suggestion.isEmpty {
            return "\(code.rawValue): \(message) — \(suggestion)"
        }
        return "\(code.rawValue): \(message)"
    }

    /// Wraps a `DecodingError` (or any other error) as an `invalidMetadata` error with context.
    public static func metadata(_ error: Error, context: String) -> LauncherError {
        if let error = error as? LauncherError { return error }
        let detail: String
        if let decoding = error as? DecodingError {
            detail = decodeDescription(decoding)
        } else {
            detail = "\(error)"
        }
        return LauncherError(.invalidMetadata, "\(context): \(detail)", suggestion: "Verify the version JSON matches Mojang's published metadata format.")
    }

    private static func decodeDescription(_ error: DecodingError) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            return "missing required field '\(key.stringValue)' at \(path(context.codingPath))"
        case let .typeMismatch(type, context):
            return "type mismatch (expected \(type)) at \(path(context.codingPath)): \(context.debugDescription)"
        case let .valueNotFound(type, context):
            return "null value (expected \(type)) at \(path(context.codingPath))"
        case let .dataCorrupted(context):
            return "corrupted data at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}

/// A single preflight finding. Errors block a launch; warnings are advisory.
public struct LaunchDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable, Equatable, Codable {
        case info
        case warning
        case error
    }

    public let severity: Severity
    public let code: LauncherError.Code?
    public let message: String
    public let suggestion: String?

    public init(severity: Severity, code: LauncherError.Code? = nil, message: String, suggestion: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.suggestion = suggestion
    }

    public static func info(_ message: String) -> LaunchDiagnostic {
        LaunchDiagnostic(severity: .info, message: message)
    }

    public static func warning(_ code: LauncherError.Code, _ message: String, suggestion: String? = nil) -> LaunchDiagnostic {
        LaunchDiagnostic(severity: .warning, code: code, message: message, suggestion: suggestion)
    }

    public static func error(_ code: LauncherError.Code, _ message: String, suggestion: String? = nil) -> LaunchDiagnostic {
        LaunchDiagnostic(severity: .error, code: code, message: message, suggestion: suggestion)
    }

    public var description: String {
        let prefix = code?.rawValue ?? severity.rawValue.uppercased()
        if let suggestion, !suggestion.isEmpty {
            return "[\(prefix)] \(message) — \(suggestion)"
        }
        return "[\(prefix)] \(message)"
    }
}
