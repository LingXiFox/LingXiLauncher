import Foundation

/// Removes credentials and local identity from diagnostic text before it leaves the machine.
public enum DiagnosticRedactor {
    private static let replacements: [(String, String)] = [
        (#"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
        (#"(?i)(access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|authorization|password|secret)\s*[:=]\s*[^\s,;]+"#, "$1=<redacted>"),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "<redacted-jwt>"),
        (#"(/Users/)[^/\s]+"#, "$1<redacted>"),
        (#"(/home/)[^/\s]+"#, "$1<redacted>"),
        (#"(?i)(?:file://)?(?:/[^\s:]+)?/\.minecraft/versions/[^/\s]+"#, "<GAME_INSTANCE>"),
    ]

    public static func redact(_ text: String) -> String {
        var output = text
        for (pattern, replacement) in replacements {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let home = NSHomeDirectory()
        if !home.isEmpty {
            output = output.replacingOccurrences(of: home, with: "~")
        }
        return output
    }

    public static func redact(_ report: CrashDiagnosticReport) -> CrashDiagnosticReport {
        let diagnostics = report.diagnostics.map { diagnostic in
            CrashDiagnostic(
                id: diagnostic.id,
                category: diagnostic.category,
                severity: diagnostic.severity,
                confidence: diagnostic.confidence,
                evidence: diagnostic.evidence.map {
                    DiagnosticEvidence(
                        source: redact($0.source),
                        line: $0.line,
                        excerpt: redact($0.excerpt)
                    )
                },
                affectedComponents: diagnostic.affectedComponents.map(redact),
                explanation: redact(diagnostic.explanation),
                recommendations: diagnostic.recommendations.map(redact),
                isRootCause: diagnostic.isRootCause,
                isSecondary: diagnostic.isSecondary
            )
        }
        let logs = report.logs.map { reference in
            DiagnosticLogReference(
                kind: reference.kind,
                name: redact(reference.name),
                url: URL(fileURLWithPath: "/<redacted>/\(reference.name)"),
                byteCount: reference.byteCount,
                modifiedAt: reference.modifiedAt
            )
        }
        return CrashDiagnosticReport(
            id: report.id,
            instanceID: report.instanceID,
            generatedAt: report.generatedAt,
            exitCode: report.exitCode,
            abnormalExit: report.abnormalExit,
            summary: redact(report.summary),
            diagnostics: diagnostics,
            rootCauseID: report.rootCauseID,
            logs: logs,
            logTexts: report.logTexts.map { CrashLogText(kind: $0.kind, name: redact($0.name), text: redact($0.text)) }
        )
    }
}

public enum CrashReportExporter {
    public static func markdown(for report: CrashDiagnosticReport, includeLogs: Bool = true) -> String {
        let safe = DiagnosticRedactor.redact(report)
        var lines: [String] = []
        lines.append("# LingXi Launcher 崩溃诊断报告")
        lines.append("")
        lines.append("- 实例：`\(safe.instanceID)`")
        lines.append("- 生成时间：\(ISO8601DateFormatter().string(from: safe.generatedAt))")
        lines.append("- 退出码：\(safe.exitCode.map(String.init) ?? "未知")")
        lines.append("- 异常退出：\(safe.abnormalExit ? "是" : "否")")
        lines.append("- 结论：\(safe.summary)")
        lines.append("")
        lines.append("> 报告由确定性规则生成，不调用 LLM。无法识别的日志会明确标记为未知原因。")
        lines.append("")
        if safe.diagnostics.isEmpty {
            lines.append("未发现可诊断的问题。")
        }
        for (index, diagnostic) in safe.diagnostics.enumerated() {
            lines.append("## \(index + 1). \(diagnostic.category.displayName)")
            lines.append("")
            lines.append("- 严重程度：\(severityName(diagnostic.severity))")
            lines.append("- 置信程度：\(confidenceName(diagnostic.confidence))")
            lines.append("- 根因：\(diagnostic.isRootCause ? "是" : "否")")
            if !diagnostic.affectedComponents.isEmpty {
                lines.append("- 涉及组件：\(diagnostic.affectedComponents.joined(separator: ", "))")
            }
            lines.append("")
            lines.append(diagnostic.explanation)
            if !diagnostic.recommendations.isEmpty {
                lines.append("")
                lines.append("### 建议")
                for recommendation in diagnostic.recommendations {
                    lines.append("- \(recommendation)")
                }
            }
            if !diagnostic.evidence.isEmpty {
                lines.append("")
                lines.append("### 关键证据")
                for evidence in diagnostic.evidence {
                    let line = evidence.line.map { ":\($0)" } ?? ""
                    lines.append("- `\(evidence.source)\(line)` — \(evidence.excerpt)")
                }
            }
            lines.append("")
        }
        if !safe.logs.isEmpty {
            lines.append("## 日志来源")
            lines.append("")
            for log in safe.logs {
                lines.append("- \(log.kind.displayName)：`\(log.name)`（\(log.byteCount) bytes）")
            }
            lines.append("")
        }
        if includeLogs, !safe.logTexts.isEmpty {
            lines.append("## 原始日志摘录")
            lines.append("")
            for log in safe.logTexts {
                lines.append("### \(log.kind.displayName) / \(log.name)")
                lines.append("```text")
                lines.append(String(log.text.suffix(12_000)))
                lines.append("```")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func json(for report: CrashDiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(DiagnosticRedactor.redact(report))
    }

    private static func severityName(_ severity: CrashDiagnosticSeverity) -> String {
        switch severity {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        case .critical: return "严重"
        }
    }

    private static func confidenceName(_ confidence: CrashDiagnosticConfidence) -> String {
        switch confidence {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}
