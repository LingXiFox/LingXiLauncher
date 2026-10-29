import Foundation

/// Minimal, property-preserving editor for Iris' `config/iris.properties`.
///
/// Iris 1.7.x uses `java.util.Properties` (ISO-8859-1 with `\uXXXX` escapes) and reads these
/// keys: `shaderPack`, `enableShaders`, `enableDebugOptions`, `disableUpdateMessage`,
/// `maxShadowRenderDistance`, `colorSpace`. We intentionally change only the first two and keep
/// every other line, comment and unknown key untouched. The caller is responsible for version
/// gating and for refusing to write while the game is running.
struct IrisConfigurationStore: Sendable {
    typealias Writer = @Sendable (Data, URL) throws -> Void

    let writer: Writer

    init(writer: @escaping Writer = { data, url in
        try data.write(to: url, options: [.atomic])
    }) {
        self.writer = writer
    }

    struct Snapshot: Sendable, Equatable {
        let shaderPack: String?
        let shadersEnabled: Bool

        var isEnabled: Bool { shadersEnabled && !(shaderPack ?? "").isEmpty }
    }

    func read(_ url: URL) throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LauncherError(.ioFailure, "无法读取 Iris 配置 \(url.path): \(error.localizedDescription)")
        }
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw LauncherError(.invalidMetadata, "Iris 配置不是可读取的文本文件")
        }
        let parsed = Self.parse(raw)
        return Snapshot(
            shaderPack: parsed.shaderPack.flatMap { $0.isEmpty ? nil : $0 },
            shadersEnabled: parsed.shadersEnabled ?? true
        )
    }

    /// Writes the selected pack atomically. Returns the backup path when a previous config
    /// existed. On any failure the original bytes are restored before the error is rethrown.
    func apply(shaderPack: String, enabled: Bool, to url: URL) throws -> (backup: URL?, data: Data) {
        try Task.checkCancellation()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw LauncherError(.ioFailure, "无法创建 Iris 配置目录: \(error.localizedDescription)")
        }

        let original: Data?
        if fm.fileExists(atPath: url.path) {
            do {
                original = try Data(contentsOf: url)
            } catch {
                throw LauncherError(.ioFailure, "无法备份 Iris 配置: \(error.localizedDescription)")
            }
        } else {
            original = nil
        }
        let raw = original.flatMap {
            String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1)
        }
        if original != nil && raw == nil {
            throw LauncherError(.invalidMetadata, "Iris 配置编码未知，拒绝覆盖")
        }
        let output = Self.updatedProperties(
            raw ?? Self.defaultProperties,
            shaderPack: shaderPack,
            enabled: enabled
        )
        guard let data = output.data(using: .utf8) else {
            throw LauncherError(.invalidMetadata, "无法编码 Iris 配置")
        }

        var backup: URL?
        if let original {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(
                ".iris.properties.lingxi-backup-\(Self.timestamp())-\(UUID().uuidString.prefix(8))"
            )
            do {
                try original.write(to: candidate, options: [.atomic])
                backup = candidate
            } catch {
                throw LauncherError(.ioFailure, "无法创建 Iris 配置备份: \(error.localizedDescription)")
            }
        }

        do {
            try writer(data, url)
            let expectedPack = shaderPack.isEmpty ? nil : shaderPack
            guard let verify = try? read(url),
                  verify.shaderPack == expectedPack,
                  verify.shadersEnabled == enabled else {
                throw LauncherError(.ioFailure, "Iris 配置写入后校验失败")
            }
            return (backup, data)
        } catch {
            // Best-effort rollback; preserve the original failure if restoration also fails.
            if let original {
                try? original.write(to: url, options: [.atomic])
            } else {
                try? fm.removeItem(at: url)
            }
            throw (error as? LauncherError) ?? LauncherError(
                .ioFailure,
                "无法写入 Iris 配置: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Properties

    struct Parsed: Equatable {
        var shaderPack: String?
        var shadersEnabled: Bool?
    }

    static func parse(_ raw: String) -> Parsed {
        var result = Parsed()
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("!") else { continue }
            guard let split = splitKeyValue(line) else { continue }
            switch split.key {
            case "shaderPack":
                result.shaderPack = unescape(split.value)
            case "enableShaders":
                result.shadersEnabled = split.value.trimmingCharacters(in: .whitespaces).lowercased() != "false"
            default:
                break
            }
        }
        return result
    }

    /// Keeps comments and all unrelated keys. The two managed keys are replaced in place, or
    /// appended if absent.
    static func updatedProperties(_ raw: String, shaderPack: String, enabled: Bool) -> String {
        let escapedPack = escape(shaderPack)
        let escapedEnabled = enabled ? "true" : "false"
        var sawPack = false
        var sawEnabled = false
        var lines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard let split = splitKeyValue(line) else {
                lines.append(line)
                continue
            }
            if split.key == "shaderPack" {
                sawPack = true
                lines.append("shaderPack=\(escapedPack)")
            } else if split.key == "enableShaders" {
                sawEnabled = true
                lines.append("enableShaders=\(escapedEnabled)")
            } else {
                lines.append(line)
            }
        }
        if !sawPack { lines.append("shaderPack=\(escapedPack)") }
        if !sawEnabled { lines.append("enableShaders=\(escapedEnabled)") }
        var output = lines.joined(separator: "\n")
        if !output.hasSuffix("\n") { output.append("\n") }
        return output
    }

    static let defaultProperties = """
    # LingXi Launcher: Iris shader configuration (managed only by explicit user action).
    shaderPack=
    enableShaders=true
    """

    private static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "=" || character == ":" {
                let key = String(line[..<index]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (key, String(line[line.index(after: index)...]))
            }
        }
        return nil
    }

    /// Java Properties syntax: backslash escapes and ISO-8859-1 unicode escapes.
    static func escape(_ value: String) -> String {
        var output = ""
        for (index, scalar) in value.unicodeScalars.enumerated() {
            switch scalar {
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "=", ":", "#", "!":
                output += "\\\(Character(scalar))"
            case " ":
                output += index == 0 ? "\\ " : " "
            default:
                if scalar.value >= 0x20 && scalar.value <= 0x7E {
                    output.append(Character(scalar))
                } else {
                    output += String(format: "\\u%04X", scalar.value)
                }
            }
        }
        return output
    }

    static func unescape(_ value: String) -> String {
        var output = ""
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\", index + 1 < scalars.count else {
                output.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            let next = scalars[index + 1]
            switch next {
            case "t": output += "\t"; index += 2
            case "n": output += "\n"; index += 2
            case "r": output += "\r"; index += 2
            case "u":
                guard index + 5 < scalars.count,
                      let code = UInt32(String(String.UnicodeScalarView(scalars[(index + 2)...(index + 4)])), radix: 16),
                      let unicode = UnicodeScalar(code) else {
                    output.unicodeScalars.append(scalar)
                    index += 1
                    continue
                }
                output.unicodeScalars.append(unicode)
                index += 6
            default:
                output.unicodeScalars.append(next)
                index += 2
            }
        }
        return output
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
