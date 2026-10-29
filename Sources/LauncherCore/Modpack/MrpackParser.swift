import Foundation

/// Parses a local Modrinth `.mrpack` into a validated, staging-backed package.
///
/// The archive is never trusted: `SafeZipExtractor` validates every entry (no traversal,
/// absolute paths, backslashes, symlinks or ZIP bombs) before the format-1 index is inspected.
public enum MrpackParser {
    public static let maximumEntrySize = 256 * 1024 * 1024
    public static let maximumTotalSize = 1024 * 1024 * 1024
    public static let maximumEntries = 20_000
    public static let maximumArchiveSize = 512 * 1024 * 1024

    /// Modrinth format 1 permits these official download hosts. Redirects are validated
    /// separately by the transport; a redirect never bypasses the hash and size checks.
    static let trustedDownloadHosts: Set<String> = [
        "cdn.modrinth.com",
        "github.com",
        "raw.githubusercontent.com",
        "gitlab.com",
    ]

    public static func parse(
        archive: URL,
        extractionRoot: URL,
        limits: SafeZipExtractor.Limits = SafeZipExtractor.Limits(
            maxEntrySize: maximumEntrySize,
            maxTotalSize: maximumTotalSize,
            maxEntries: maximumEntries
        )
    ) throws -> MrpackPackage {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: archive.path) else {
            throw LauncherError(.missingDependency, "整合包不存在：\(archive.path)")
        }
        if let archiveSize = try? fileManager.attributesOfItem(atPath: archive.path)[.size] as? NSNumber,
           archiveSize.intValue > maximumArchiveSize {
            throw LauncherError(.invalidMetadata, "整合包归档超过 \(maximumArchiveSize) 字节上限")
        }
        guard !fileManager.fileExists(atPath: extractionRoot.path) else {
            throw LauncherError(.usageError, "整合包临时目录已存在：\(extractionRoot.path)")
        }
        let archiveSHA256: String
        do {
            archiveSHA256 = try SHA256Digest.hexDigest(ofFileAt: archive)
        } catch {
            throw LauncherError(.ioFailure, "无法读取整合包：\(error.localizedDescription)")
        }

        do {
            try SafeZipExtractor.extract(archive: archive, into: extractionRoot, limits: limits)
            let indexURL = extractionRoot.appendingPathComponent("modrinth.index.json", isDirectory: false)
            guard fileManager.fileExists(atPath: indexURL.path) else {
                throw LauncherError(.invalidMetadata, "整合包缺少根目录 modrinth.index.json")
            }
            let index: MrpackIndex
            do {
                index = try JSONDecoder().decode(MrpackIndex.self, from: Data(contentsOf: indexURL))
            } catch {
                throw LauncherError(.invalidMetadata, "modrinth.index.json 格式无效：\(error.localizedDescription)")
            }
            guard index.formatVersion == 1 else {
                throw LauncherError(.unsupportedVersion, "不支持的 .mrpack formatVersion：\(index.formatVersion)（当前支持 1）")
            }
            guard index.game.lowercased() == "minecraft" else {
                throw LauncherError(.unsupportedVersion, "整合包 game 必须是 minecraft，实际为 \(index.game)")
            }
            let name = index.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw LauncherError(.invalidMetadata, "整合包 name 不能为空")
            }
            let versionID = (index.versionId ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !versionID.isEmpty else {
                throw LauncherError(.invalidMetadata, "整合包 versionId 不能为空")
            }
            guard let minecraftVersion = index.dependencies["minecraft"], !minecraftVersion.isEmpty else {
                throw LauncherError(.invalidMetadata, "整合包 dependencies 缺少 minecraft 版本")
            }
            _ = try PathSafety.validatedPathComponent(minecraftVersion)

            let normalizedDependencies = Dictionary(uniqueKeysWithValues: index.dependencies.map {
                ($0.key.lowercased(), $0.value)
            })
            let unsupported = ["forge", "quilt-loader", "quilt"].filter {
                normalizedDependencies[$0] != nil
            }
            guard unsupported.isEmpty else {
                throw LauncherError(
                    .unsupportedVersion,
                    "当前只支持 Vanilla/Fabric/NeoForge 整合包，检测到 \(unsupported.joined(separator: ", "))",
                    suggestion: "请使用 Fabric/NeoForge 版本，或等待 Forge/Quilt 支持。"
                )
            }
            let loader: InstallLoaderChoice
            if let fabricVersion = normalizedDependencies["fabric-loader"] {
                loader = .fabric(loaderVersion: fabricVersion.isEmpty ? nil : fabricVersion)
            } else if let neoForgeVersion = normalizedDependencies["neoforge"] {
                loader = .neoforge(loaderVersion: neoForgeVersion.isEmpty ? nil : neoForgeVersion)
            } else {
                loader = .vanilla
            }

            var files: [MrpackFile] = []
            var seenPaths = Set<String>()
            var skippedClientUnsupported = 0
            for raw in index.files {
                let path = try validatedRelativePath(raw.path)
                guard path != "modrinth.index.json" else {
                    throw LauncherError(.invalidMetadata, "整合包文件不能覆盖 modrinth.index.json")
                }
                guard seenPaths.insert(path.lowercased()).inserted else {
                    throw LauncherError(.invalidMetadata, "整合包包含重复文件路径（不区分大小写）：\(path)")
                }

                let clientEnvironment = (raw.env?.client ?? "required").lowercased()
                guard ["required", "optional", "unsupported"].contains(clientEnvironment) else {
                    throw LauncherError(.invalidMetadata, "\(path) 的 env.client 值无效：\(clientEnvironment)")
                }
                if clientEnvironment == "unsupported" {
                    skippedClientUnsupported += 1
                    continue
                }

                guard let size = raw.fileSize, size > 0 else {
                    throw LauncherError(.invalidMetadata, "\(path) 缺少有效 fileSize")
                }
                let sha1 = try validatedHash(raw.hashes?.sha1, length: 40, field: "sha1", path: path)
                let sha512 = try validatedHash(raw.hashes?.sha512, length: 128, field: "sha512", path: path)
                guard sha1 != nil || sha512 != nil else {
                    throw LauncherError(
                        .invalidMetadata,
                        "\(path) 没有发布 SHA-1/SHA-512；拒绝跳过校验安装"
                    )
                }
                guard let downloadURL = raw.downloads.compactMap({ URL(string: $0) }).first(where: isTrustedDownloadURL) else {
                    throw LauncherError(
                        .invalidMetadata,
                        "\(path) 没有可信的 Modrinth 下载地址",
                        suggestion: "仅允许 Modrinth 官方认可的 cdn.modrinth.com、github.com、raw.githubusercontent.com、gitlab.com HTTPS 地址；不会跳过校验或改用未知外部地址。"
                    )
                }
                files.append(MrpackFile(
                    relativePath: path,
                    sha1: sha1,
                    sha512: sha512,
                    downloadURL: downloadURL,
                    fileSize: size,
                    clientEnvironment: clientEnvironment
                ))
            }

            let overrides = try collectOverrides(from: extractionRoot)

            return MrpackPackage(
                archiveURL: archive,
                archiveSHA256: archiveSHA256,
                name: name,
                versionID: versionID,
                summary: index.summary,
                minecraftVersion: minecraftVersion,
                loader: loader,
                files: files,
                overrides: overrides,
                skippedClientUnsupported: skippedClientUnsupported,
                extractionRoot: extractionRoot
            )
        } catch {
            try? fileManager.removeItem(at: extractionRoot)
            if let launcherError = error as? LauncherError { throw launcherError }
            throw LauncherError(.invalidMetadata, "无法解析整合包：\(error.localizedDescription)")
        }
    }

    private static func validatedRelativePath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasSuffix("/"), path != "." else {
            throw LauncherError(.invalidMetadata, "整合包文件路径无效：\(raw)")
        }
        _ = try PathSafety.validatedArchiveEntry(path)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LauncherError(.pathEscapesRoot, "整合包文件路径包含非法组件：\(raw)")
        }
        return path
    }

    private static func validatedHash(
        _ raw: String?,
        length: Int,
        field: String,
        path: String
    ) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let value = raw.lowercased()
        guard value.count == length, value.allSatisfy({ $0.isHexDigit }) else {
            throw LauncherError(.invalidMetadata, "\(path) 的 \(field) 不是有效的 \(length) 位十六进制摘要")
        }
        return value
    }

    /// Internal for regression tests; the public parser is the only production caller.
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              trustedDownloadHosts.contains(host),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              !url.path.isEmpty, url.path != "/" else { return false }
        return true
    }

    private static func collectOverrides(from root: URL) throws -> [MrpackOverride] {
        let fileManager = FileManager.default
        var byPath: [String: URL] = [:]
        for prefix in ["overrides", "client-overrides"] {
            let directory = root.appendingPathComponent(prefix, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw LauncherError(.pathEscapesRoot, "整合包 overrides 包含符号链接：\(file.path)")
                }
                guard values.isRegularFile == true else { continue }
                let canonicalDirectory = directory.resolvingSymlinksInPath().path
                let canonicalFile = file.resolvingSymlinksInPath().path
                guard canonicalFile.hasPrefix(canonicalDirectory + "/") else {
                    throw LauncherError(.pathEscapesRoot, "overrides 文件逃逸：\(file.path)")
                }
                let relative = String(canonicalFile.dropFirst(canonicalDirectory.count + 1))
                let path = try validatedRelativePath(relative)
                // client-overrides is applied after overrides, matching the Modrinth format.
                byPath[path] = file
            }
        }
        return byPath.map { MrpackOverride(relativePath: $0.key, sourceURL: $0.value) }
            .sorted { $0.relativePath < $1.relativePath }
    }
}
