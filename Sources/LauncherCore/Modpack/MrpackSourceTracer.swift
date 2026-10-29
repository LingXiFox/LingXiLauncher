import Foundation

/// Result of the best-effort provenance lookup after a `.mrpack` import. A failure to identify a
/// file is not an install failure: the jar remains a managed `local` mod.
public struct MrpackSourceTraceSummary: Sendable, Equatable {
    public let identifiedFiles: Int
    public let localFiles: Int
    public let warnings: [String]

    public init(identifiedFiles: Int, localFiles: Int, warnings: [String]) {
        self.identifiedFiles = identifiedFiles
        self.localFiles = localFiles
        self.warnings = warnings
    }

    public static let empty = MrpackSourceTraceSummary(identifiedFiles: 0, localFiles: 0, warnings: [])
}

/// Resolves `.mrpack` external mod files through Modrinth's official hash lookup. Only a version
/// whose file hash matches the downloaded bytes is accepted; project titles/licenses are fetched
/// separately and are allowed to be unavailable without turning the file into a fake source.
public struct MrpackSourceTracer: Sendable {
    private struct Candidate {
        let file: MrpackFile
        let fileName: String
    }

    private let client: ModrinthClient

    public init(client: ModrinthClient = ModrinthClient()) {
        self.client = client
    }

    public func trace(
        instance: Instance,
        files: [MrpackFile],
        repository: ModRepository
    ) async -> MrpackSourceTraceSummary {
        let candidates = files.compactMap(Self.candidate(from:))
        guard !candidates.isEmpty else { return .empty }

        let records = (try? repository.list(instance: instance)) ?? []
        let tracked = Set(records.map(\.fileName))
        let installed = candidates.filter { tracked.contains($0.fileName) }
        guard !installed.isEmpty else {
            return MrpackSourceTraceSummary(identifiedFiles: 0, localFiles: candidates.count, warnings: [])
        }

        var warnings: [String] = []
        var versionsByHash: [String: ModrinthVersion] = [:]

        var bySHA1: [String: Candidate] = [:]
        var bySHA512: [String: Candidate] = [:]
        for candidate in installed {
            if let sha1 = candidate.file.sha1 {
                bySHA1[sha1.lowercased()] = candidate
            } else if let sha512 = candidate.file.sha512 {
                bySHA512[sha512.lowercased()] = candidate
            }
        }

        if !bySHA1.isEmpty {
            do {
                versionsByHash.merge(
                    try await client.versions(forHashes: Array(bySHA1.keys), algorithm: .sha1),
                    uniquingKeysWith: { first, _ in first }
                )
            } catch {
                Self.appendWarning("Modrinth 来源识别失败：\(error.localizedDescription)", to: &warnings)
            }
        }
        if !bySHA512.isEmpty {
            do {
                versionsByHash.merge(
                    try await client.versions(forHashes: Array(bySHA512.keys), algorithm: .sha512),
                    uniquingKeysWith: { first, _ in first }
                )
            } catch {
                Self.appendWarning("Modrinth SHA-512 来源识别失败：\(error.localizedDescription)", to: &warnings)
            }
        }

        var projects: [String: ModrinthProject] = [:]
        var identified = 0
        for (hash, version) in versionsByHash {
            let candidate = bySHA1[hash] ?? bySHA512[hash]
            guard let candidate else { continue }
            guard let matchingFile = version.files.first(where: { file in
                if let expected = candidate.file.sha1,
                   let actual = file.hashes.sha1,
                   expected.caseInsensitiveCompare(actual) == .orderedSame {
                    return true
                }
                if let expected = candidate.file.sha512,
                   let actual = file.hashes.sha512,
                   expected.caseInsensitiveCompare(actual) == .orderedSame {
                    return true
                }
                return false
            }) else {
                Self.appendWarning("\(candidate.fileName) 的 Modrinth 版本哈希不匹配，保留为本地模组", to: &warnings)
                continue
            }

            if projects[version.projectID] == nil {
                do {
                    projects[version.projectID] = try await client.project(idOrSlug: version.projectID)
                } catch {
                    Self.appendWarning("无法读取 \(version.projectID) 的项目信息：\(error.localizedDescription)", to: &warnings)
                }
            }
            let project = projects[version.projectID]
            let title = project?.title.nonEmpty
                ?? version.name.nonEmpty
                ?? version.versionNumber.nonEmpty
                ?? candidate.fileName
            do {
                _ = try repository.attachSource(
                    instance: instance,
                    fileName: candidate.fileName,
                    projectID: version.projectID,
                    slug: project?.slug,
                    title: title,
                    versionID: version.id,
                    versionNumber: version.versionNumber.nonEmpty,
                    sha1: matchingFile.hashes.sha1,
                    sha512: matchingFile.hashes.sha512,
                    license: project?.license?.displayName,
                    iconURL: project?.iconURL
                )
                identified += 1
            } catch {
                Self.appendWarning("无法写入 \(candidate.fileName) 的来源信息：\(error.localizedDescription)", to: &warnings)
            }
        }

        return MrpackSourceTraceSummary(
            identifiedFiles: identified,
            localFiles: max(0, candidates.count - identified),
            warnings: warnings
        )
    }

    private static func candidate(from file: MrpackFile) -> Candidate? {
        let components = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "mods",
              components[1].lowercased().hasSuffix(".jar") else { return nil }
        guard file.sha1 != nil || file.sha512 != nil else { return nil }
        return Candidate(file: file, fileName: String(components[1]))
    }

    private static func appendWarning(_ warning: String, to warnings: inout [String]) {
        guard warnings.count < 20, !warnings.contains(warning) else { return }
        warnings.append(warning)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
