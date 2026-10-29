import Foundation

public enum CrashDiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case javaVersion
    case javaArchitecture
    case minecraftVersion
    case loaderVersion
    case missingRequiredMod
    case modVersionConflict
    case modInitialization
    case lwjglNative
    case openGL
    case irisShader
    case outOfMemory
    case missingOrCorruptFiles
    case unknown

    public var displayName: String {
        switch self {
        case .javaVersion: return "Java 版本不匹配"
        case .javaArchitecture: return "Java 架构不匹配"
        case .minecraftVersion: return "Minecraft 版本不兼容"
        case .loaderVersion: return "Mod Loader 版本错误"
        case .missingRequiredMod: return "缺少必需模组"
        case .modVersionConflict: return "模组版本冲突"
        case .modInitialization: return "模组初始化异常"
        case .lwjglNative: return "LWJGL / Native Library 错误"
        case .openGL: return "OpenGL 初始化失败"
        case .irisShader: return "Iris 光影编译异常"
        case .outOfMemory: return "内存不足"
        case .missingOrCorruptFiles: return "游戏文件缺失或损坏"
        case .unknown: return "未知原因"
        }
    }
}

public enum CrashDiagnosticSeverity: String, Codable, Sendable {
    case info, warning, error, critical

    var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        case .critical: return 3
        }
    }
}

public enum CrashDiagnosticConfidence: String, Codable, Sendable {
    case low, medium, high
}

public enum CrashLogKind: String, Codable, Sendable {
    case latestLog
    case crashReport
    case launcherLog
    case gameOutput

    public var displayName: String {
        switch self {
        case .latestLog: return "游戏 latest.log"
        case .crashReport: return "Minecraft crash-report"
        case .launcherLog: return "启动器日志"
        case .gameOutput: return "Java 输出"
        }
    }
}

public struct DiagnosticLogReference: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: CrashLogKind
    public let name: String
    public let url: URL
    public let byteCount: Int
    public let modifiedAt: Date?

    public init(kind: CrashLogKind, name: String, url: URL, byteCount: Int, modifiedAt: Date?) {
        self.id = "\(kind.rawValue):\(url.path)"
        self.kind = kind
        self.name = name
        self.url = url
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

/// Text loaded from one log source. Kept separate from the file reference so tests can analyze
/// fixtures without creating a real Minecraft installation.
public struct CrashLogText: Codable, Sendable, Equatable {
    public let kind: CrashLogKind
    public let name: String
    public let text: String

    public init(kind: CrashLogKind, name: String, text: String) {
        self.kind = kind
        self.name = name
        self.text = text
    }
}

public struct DiagnosticEvidence: Codable, Sendable, Equatable {
    public let source: String
    public let line: Int?
    public let excerpt: String

    public init(source: String, line: Int?, excerpt: String) {
        self.source = source
        self.line = line
        self.excerpt = excerpt
    }
}

public struct CrashDiagnostic: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let category: CrashDiagnosticCategory
    public let severity: CrashDiagnosticSeverity
    public let confidence: CrashDiagnosticConfidence
    public let evidence: [DiagnosticEvidence]
    public let affectedComponents: [String]
    public let explanation: String
    public let recommendations: [String]
    public let isRootCause: Bool
    public let isSecondary: Bool

    public init(
        id: String = UUID().uuidString,
        category: CrashDiagnosticCategory,
        severity: CrashDiagnosticSeverity,
        confidence: CrashDiagnosticConfidence,
        evidence: [DiagnosticEvidence],
        affectedComponents: [String],
        explanation: String,
        recommendations: [String],
        isRootCause: Bool = false,
        isSecondary: Bool = false
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.confidence = confidence
        self.evidence = evidence
        self.affectedComponents = affectedComponents
        self.explanation = explanation
        self.recommendations = recommendations
        self.isRootCause = isRootCause
        self.isSecondary = isSecondary
    }
}

public struct CrashDiagnosticReport: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let instanceID: String
    public let generatedAt: Date
    public let exitCode: Int32?
    public let abnormalExit: Bool
    public let summary: String
    public let diagnostics: [CrashDiagnostic]
    public let rootCauseID: String?
    public let logs: [DiagnosticLogReference]
    public let logTexts: [CrashLogText]

    public init(
        id: String = UUID().uuidString,
        instanceID: String,
        generatedAt: Date = Date(),
        exitCode: Int32?,
        abnormalExit: Bool,
        summary: String,
        diagnostics: [CrashDiagnostic],
        rootCauseID: String?,
        logs: [DiagnosticLogReference],
        logTexts: [CrashLogText] = []
    ) {
        self.id = id
        self.instanceID = instanceID
        self.generatedAt = generatedAt
        self.exitCode = exitCode
        self.abnormalExit = abnormalExit
        self.summary = summary
        self.diagnostics = diagnostics
        self.rootCauseID = rootCauseID
        self.logs = logs
        self.logTexts = logTexts
    }

    public var rootCause: CrashDiagnostic? {
        guard let rootCauseID else { return nil }
        return diagnostics.first { $0.id == rootCauseID }
    }
}
