import Foundation

/// Collects instance-scoped logs and classifies known crash signatures with deterministic rules.
/// It never guesses a cause when no signature matches; an empty match set becomes `.unknown`.
public struct CrashDiagnosticsService: Sendable {
    private struct Rule: Sendable {
        let category: CrashDiagnosticCategory
        let severity: CrashDiagnosticSeverity
        let confidence: CrashDiagnosticConfidence
        let patterns: [String]
        let priority: Int
        let explanation: String
        let recommendations: [String]
    }

    private struct Candidate {
        var category: CrashDiagnosticCategory
        var severity: CrashDiagnosticSeverity
        var confidence: CrashDiagnosticConfidence
        var priority: Int
        var evidence: [DiagnosticEvidence]
        var explanation: String
        var recommendations: [String]
        var components: Set<String>
    }

    private static let rules: [Rule] = [
        Rule(
            category: .outOfMemory,
            severity: .critical,
            confidence: .high,
            patterns: [
                #"java\.lang\.OutOfMemoryError"#,
                #"Java heap space"#,
                #"GC overhead limit exceeded"#,
                #"Could not reserve enough space for .* object heap"#,
            ],
            priority: 100,
            explanation: "Java 虚拟机无法获得足够的内存，通常是实例内存上限过低或模组/光影占用过高。",
            recommendations: ["降低渲染距离或光影质量", "提高实例内存上限并重启游戏", "检查是否安装了过多大型模组"]
        ),
        Rule(
            category: .javaVersion,
            severity: .critical,
            confidence: .high,
            patterns: [
                #"UnsupportedClassVersionError"#,
                #"class file version"#,
                #"requires Java [0-9]+"#,
                #"Java [0-9]+.*(is required|required)"#,
                #"Unsupported Java"#,
            ],
            priority: 98,
            explanation: "当前 Java 版本低于游戏或 Mod Loader 要求，字节码无法被加载。",
            recommendations: ["在实例设置或安装向导中选择兼容的 Java 版本", "重新启动启动器后再试"]
        ),
        Rule(
            category: .javaArchitecture,
            severity: .critical,
            confidence: .high,
            patterns: [
                #"wrong ELF class"#,
                #"incompatible architecture"#,
                #"Mach-O.*(x86_64|arm64)"#,
                #"(x86_64.*arm64|arm64.*x86_64)"#,
                #"Bad CPU type in executable"#,
            ],
            priority: 97,
            explanation: "Java 或 Native Library 的 CPU 架构与当前 Mac 不匹配。Apple Silicon 上应使用 arm64 或通用 Java。",
            recommendations: ["安装 arm64 或 universal Java 21", "删除实例中不兼容的 native 模组并重新安装"]
        ),
        Rule(
            category: .missingOrCorruptFiles,
            severity: .critical,
            confidence: .high,
            patterns: [
                #"FileNotFoundException"#,
                #"NoSuchFileException"#,
                #"ZipException"#,
                #"invalid LOC header"#,
                #"invalid stored block lengths"#,
                #"corrupt"#,
                #"Failed to download .* (404|403)"#,
            ],
            priority: 92,
            explanation: "启动所需的游戏文件、libraries 或模组 JAR 缺失/损坏，加载过程被中断。",
            recommendations: ["在实例管理中运行完整性检查", "重新安装对应模组或验证游戏文件", "不要手动删除 libraries 目录"]
        ),
        Rule(
            category: .loaderVersion,
            severity: .error,
            confidence: .high,
            patterns: [
                #"Fabric Loader .* requires"#,
                #"NeoForge .* requires"#,
                #"Unsupported loader"#,
                #"Loader version .* is not supported"#,
                #"requires Fabric Loader"#,
                #"requires NeoForge"#,
            ],
            priority: 86,
            explanation: "Mod Loader 版本与模组或游戏版本不兼容。",
            recommendations: ["安装向导中选择匹配的 Fabric/NeoForge 版本", "确认 Minecraft 版本与 Loader 主版本一致"]
        ),
        Rule(
            category: .minecraftVersion,
            severity: .error,
            confidence: .medium,
            patterns: [
                #"Minecraft version .* is not supported"#,
                #"requires Minecraft .* but"#,
                #"Incompatible Minecraft version"#,
                #"Minecraft .* is required"#,
                #"does not support Minecraft"#,
            ],
            priority: 82,
            explanation: "模组或 Loader 声明支持的 Minecraft 版本与实例版本不一致。",
            recommendations: ["切换到实例对应的 Minecraft 版本", "安装该版本兼容的模组版本"]
        ),
        Rule(
            category: .missingRequiredMod,
            severity: .error,
            confidence: .high,
            patterns: [
                #"fabric-api.*(missing|not installed|requires)"#,
                #"Missing or unsupported mandatory dependencies"#,
                #"requires .* which is not installed"#,
                #"requires .* not installed"#,
                #"Mod .* requires .* (missing|not found)"#,
            ],
            priority: 76,
            explanation: "某个模组的前置依赖没有安装，Loader 在初始化前就停止了加载。",
            recommendations: ["打开模组管理，安装日志中列出的前置模组", "确认前置模组与当前 Loader 和 Minecraft 版本兼容"]
        ),
        Rule(
            category: .modVersionConflict,
            severity: .error,
            confidence: .high,
            patterns: [
                #"incompatible mods"#,
                #"Mod resolution"#,
                #"duplicate mods"#,
                #"multiple versions of"#,
                #"conflicting mod"#,
                #"Conflicting versions"#,
            ],
            priority: 72,
            explanation: "两个或多个模组声明了互相冲突的版本、ID 或依赖范围，Loader 无法完成解析。",
            recommendations: ["检查模组管理中的重复模组", "只保留与当前 Minecraft 版本兼容的同名模组", "查看日志中列出的冲突模组后逐个禁用测试"]
        ),
        Rule(
            category: .lwjglNative,
            severity: .error,
            confidence: .high,
            patterns: [
                #"UnsatisfiedLinkError"#,
                #"NoClassDefFoundError: org/lwjgl"#,
                #"Failed to load.*(lwjgl|native)"#,
                #"native library.*(failed|not found)"#,
                #"org\.lwjgl\..*(Exception|Error)"#,
            ],
            priority: 66,
            explanation: "LWJGL 或本地 Native Library 加载失败，常见于架构错误、文件损坏或系统库缺失。",
            recommendations: ["运行游戏文件完整性检查", "确认 Java 架构与系统一致", "删除损坏的 libraries 后重新安装游戏"]
        ),
        Rule(
            category: .openGL,
            severity: .error,
            confidence: .high,
            patterns: [
                #"GLFW error"#,
                #"OpenGL.*(failed|error|unsupported)"#,
                #"Could not create (window|OpenGL context)"#,
                #"Pixel format not accelerated"#,
                #"GL_INVALID"#,
            ],
            priority: 62,
            explanation: "OpenGL 上下文或窗口创建失败。macOS 通过 Metal 兼容层提供 OpenGL 4.1，部分驱动/远程桌面/虚拟机环境会限制该能力。",
            recommendations: ["确认当前不是无 GPU 的虚拟机或远程会话", "更新 macOS 与显卡驱动", "降低光影或关闭高级图形选项后重试"]
        ),
        Rule(
            category: .modInitialization,
            severity: .error,
            confidence: .medium,
            patterns: [
                #"Exception during mod initialization"#,
                #"Failed to (load|initialize) mod"#,
                #"ModInitializer.*(Exception|Error)"#,
                #"Caused by:.*mod"#,
            ],
            priority: 56,
            explanation: "某个模组在初始化阶段抛出了异常。日志中的 Caused by 堆栈通常能指出具体模组。",
            recommendations: ["根据日志中的模组 ID 禁用最近安装的模组", "更新该模组到支持当前 Minecraft/Loader 的版本"]
        ),
        Rule(
            category: .irisShader,
            severity: .warning,
            confidence: .medium,
            patterns: [
                #"Iris.*(shader|compile).*(error|failed|exception)"#,
                #"shader.*(compilation|compile).*(failed|error)"#,
                #"Failed to compile shader"#,
                #"Shader compilation failed"#,
            ],
            priority: 42,
            explanation: "Iris 在编译光影程序时失败，可能是光影版本、驱动或模组组合不兼容。",
            recommendations: ["切换到其他光影或更新 Iris/Sodium", "确认光影支持当前 Minecraft 版本", "尝试关闭光影后启动以确认问题来源"]
        ),
    ]

    public let layout: GameDataLayout
    public let repository: InstanceRepository

    public init(layout: GameDataLayout) {
        self.layout = layout
        self.repository = InstanceRepository(layout: layout)
    }

    /// Collects logs for one instance. Sources are filtered by an instance marker in launcher
    /// logs so logs from another instance can never be attributed to this instance.
    public func collect(instanceID: String, exitCode explicitExitCode: Int32? = nil) throws -> CrashDiagnosticReport {
        let instance = try repository.load(id: instanceID)
        guard PathSafety.isContainedResolvingSymlinks(instance.gameDirectory, inBase: layout.minecraftDirectory) else {
            throw LauncherError(.pathEscapesRoot, "Instance game directory resolves outside .minecraft")
        }

        var logs: [DiagnosticLogReference] = []
        var texts: [CrashLogText] = []
        let fm = FileManager.default
        let gameDir = instance.gameDirectory

        let latest = gameDir.appendingPathComponent("logs/latest.log", isDirectory: false)
        if let text = try readLog(latest, maxBytes: 4 * 1024 * 1024) {
            let ref = makeReference(kind: .latestLog, url: latest, text: text, fm: fm)
            logs.append(ref)
            texts.append(CrashLogText(kind: .latestLog, name: "latest.log", text: text))
        }

        let crashDir = gameDir.appendingPathComponent("crash-reports", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: crashDir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let reports = entries
                .filter { $0.pathExtension.lowercased() == "txt" }
                .sorted { modificationDate($0) > modificationDate($1) }
                .prefix(6)
            for url in reports {
                if let text = try readLog(url, maxBytes: 8 * 1024 * 1024) {
                    let ref = makeReference(kind: .crashReport, url: url, text: text, fm: fm)
                    logs.append(ref)
                    texts.append(CrashLogText(kind: .crashReport, name: url.lastPathComponent, text: text))
                }
            }
        }

        let launcherDir = layout.launcherLogsDirectory
        if let entries = try? fm.contentsOfDirectory(at: launcherDir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let files = entries
                .filter { $0.pathExtension.lowercased() == "log" }
                .sorted { modificationDate($0) > modificationDate($1) }
            var matched = 0
            for url in files where matched < 8 {
                guard let text = try readLog(url, maxBytes: 4 * 1024 * 1024) else { continue }
                guard belongs(text, to: instanceID) else { continue }
                let ref = makeReference(kind: .launcherLog, url: url, text: text, fm: fm)
                logs.append(ref)
                texts.append(CrashLogText(kind: .launcherLog, name: url.lastPathComponent, text: text))
                matched += 1
            }
        }

        let parsedExit = explicitExitCode ?? exitCode(from: texts)
        let abnormal = (parsedExit.map { $0 != 0 } ?? false) || logs.contains { $0.kind == .crashReport }
        let report = analyze(instanceID: instanceID, logs: texts, exitCode: parsedExit, abnormalExit: abnormal, references: logs)
        return report
    }

    /// Pure analysis entry point used by tests and by the collector.
    public func analyze(
        instanceID: String,
        logs: [CrashLogText],
        exitCode: Int32?,
        abnormalExit: Bool? = nil,
        references: [DiagnosticLogReference] = []
    ) -> CrashDiagnosticReport {
        var candidates: [CrashDiagnosticCategory: Candidate] = [:]
        for log in logs.sorted(by: { logPriority($0.kind) < logPriority($1.kind) }) {
            let lines = log.text.split(separator: "\n", omittingEmptySubsequences: false)
            for rule in Self.rules {
                for (index, rawLine) in lines.enumerated() {
                    let line = String(rawLine)
                    guard rule.patterns.contains(where: { line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) else {
                        continue
                    }
                    let evidence = DiagnosticEvidence(
                        source: "\(log.kind.displayName)/\(log.name)",
                        line: index + 1,
                        excerpt: String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
                    )
                    if var existing = candidates[rule.category] {
                        if existing.evidence.count < 3 {
                            existing.evidence.append(evidence)
                        }
                        if rule.severity.rank > existing.severity.rank { existing.severity = rule.severity }
                        if confidenceRank(rule.confidence) > confidenceRank(existing.confidence) { existing.confidence = rule.confidence }
                        existing.components.formUnion(components(in: line))
                        candidates[rule.category] = existing
                    } else {
                        candidates[rule.category] = Candidate(
                            category: rule.category,
                            severity: rule.severity,
                            confidence: rule.confidence,
                            priority: rule.priority,
                            evidence: [evidence],
                            explanation: rule.explanation,
                            recommendations: rule.recommendations,
                            components: components(in: line)
                        )
                    }
                    break
                }
            }
        }

        let ordered = candidates.values.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.category.rawValue < $1.category.rawValue
        }
        let isAbnormal = abnormalExit ?? (exitCode.map { $0 != 0 } ?? false)
        if ordered.isEmpty {
            let unknown = CrashDiagnostic(
                category: .unknown,
                severity: isAbnormal ? .warning : .info,
                confidence: .low,
                evidence: [],
                affectedComponents: [],
                explanation: isAbnormal
                    ? "检测到游戏异常退出，但日志中没有匹配到已知崩溃模式，因此无法可靠判断具体原因。"
                    : "最近一次启动没有发现已知崩溃模式。",
                recommendations: isAbnormal
                    ? ["查看原始日志中的最后 100 行", "关闭最近安装的模组后重试", "导出报告以便进一步排查"]
                    : [],
                isRootCause: isAbnormal,
                isSecondary: false
            )
            return CrashDiagnosticReport(
                instanceID: instanceID,
                exitCode: exitCode,
                abnormalExit: isAbnormal,
                summary: isAbnormal ? "启动异常，原因未知" : "未发现已知崩溃模式",
                diagnostics: [unknown],
                rootCauseID: isAbnormal ? unknown.id : nil,
                logs: references,
                logTexts: logs
            )
        }

        var diagnostics: [CrashDiagnostic] = []
        for (index, candidate) in ordered.enumerated() {
            let root = index == 0
            diagnostics.append(CrashDiagnostic(
                category: candidate.category,
                severity: candidate.severity,
                confidence: candidate.confidence,
                evidence: candidate.evidence,
                affectedComponents: candidate.components.sorted(),
                explanation: candidate.explanation,
                recommendations: candidate.recommendations,
                isRootCause: root,
                isSecondary: !root
            ))
        }
        let root = diagnostics[0]
        let summary = root.category == .unknown
            ? "启动异常，原因未知"
            : "\(root.category.displayName)：\(root.explanation)"
        return CrashDiagnosticReport(
            instanceID: instanceID,
            exitCode: exitCode,
            abnormalExit: isAbnormal,
            summary: summary,
            diagnostics: diagnostics,
            rootCauseID: root.id,
            logs: references,
            logTexts: logs
        )
    }

    // MARK: - Collection helpers

    private func belongs(_ text: String, to instanceID: String) -> Bool {
        text.range(of: "# instance: \(instanceID)\n", options: [.literal]) != nil
            || text.range(of: "# instance: \(instanceID)\r\n", options: [.literal]) != nil
    }

    private func exitCode(from logs: [CrashLogText]) -> Int32? {
        let pattern = #"\[launcher\] exited code=(-?[0-9]+)"#
        for log in logs.sorted(by: { logPriority($0.kind) < logPriority($1.kind) }) {
            let ns = log.text as NSString
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: log.text, range: NSRange(location: 0, length: ns.length))
            if let last = matches.last, last.numberOfRanges > 1 {
                return Int32(ns.substring(with: last.range(at: 1)))
            }
        }
        return nil
    }

    private func makeReference(kind: CrashLogKind, url: URL, text: String, fm: FileManager) -> DiagnosticLogReference {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return DiagnosticLogReference(
            kind: kind,
            name: url.lastPathComponent,
            url: url,
            byteCount: (attrs?[.size] as? NSNumber)?.intValue ?? text.utf8.count,
            modifiedAt: attrs?[.modificationDate] as? Date
        )
    }

    private func readLog(_ url: URL, maxBytes: Int) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        guard PathSafety.isContainedResolvingSymlinks(url, inBase: layout.minecraftDirectory)
            || PathSafety.isContainedResolvingSymlinks(url, inBase: layout.launcherLogsDirectory)
        else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = Int(values.fileSize ?? 0)
            if size > maxBytes {
                try handle.seek(toOffset: UInt64(size - maxBytes))
            }
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read diagnostic log \(url.path): \(error.localizedDescription)")
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func logPriority(_ kind: CrashLogKind) -> Int {
        switch kind {
        case .crashReport: return 0
        case .latestLog: return 1
        case .launcherLog: return 2
        case .gameOutput: return 3
        }
    }

    private func confidenceRank(_ confidence: CrashDiagnosticConfidence) -> Int {
        switch confidence {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    private func components(in line: String) -> Set<String> {
        var values: Set<String> = []
        if let regex = try? NSRegularExpression(pattern: #"([A-Za-z0-9_.+\-]+\.jar)"#, options: [.caseInsensitive]) {
            let ns = line as NSString
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
                values.insert(URL(fileURLWithPath: ns.substring(with: match.range(at: 1))).lastPathComponent)
            }
        }
        let lower = line.lowercased()
        for name in ["fabric-api", "fabric loader", "neoforge", "iris", "sodium", "minecraft", "lwjgl", "opengl"] where lower.contains(name) {
            values.insert(name)
        }
        return values
    }
}
