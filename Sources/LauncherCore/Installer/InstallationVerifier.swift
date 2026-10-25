import Foundation

/// Verifies every file a launch needs against the SHA-1/size values published in the metadata.
///
/// This is the M2 `lingxi verify` implementation: unlike the M1 preflight (existence/size only)
/// it streams every expected file through SHA-1, including each asset object referenced by the
/// asset index. Read-only: it never repairs anything.
public struct InstallationVerifier: Sendable {
    private let layout: GameDataLayout

    public init(layout: GameDataLayout) {
        self.layout = layout
    }

    /// - Parameter platformOverride: the selected JVM platform. Defaults to the launcher host
    ///   architecture only when no JVM has been chosen (tests, or `verify` without `--java`).
    public func verify(instance: Instance, platform platformOverride: PlatformContext? = nil) throws -> VerificationReport {
        guard let versionID = instance.manifest.versionID else {
            throw LauncherError(
                .usageError,
                "Instance '\(instance.id)' has no version assigned",
                suggestion: "Run `lingxi install vanilla --version <id> --instance \(instance.id)`."
            )
        }
        let version = try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
        let platform = try platformOverride ?? PlatformContext.current()
        let dependencies = try DependencyResolver(ruleEvaluator: RuleEvaluator())
            .resolve(version: version, layout: layout, platform: platform)
        let assetIndex = Self.loadAssetIndex(layout: layout, version: version)
        return try verify(version: version, dependencies: dependencies, assetIndex: assetIndex)
    }

    public func verify(
        version: ResolvedVersion,
        dependencies: DependencyResolution,
        assetIndex: AssetIndexDocument?
    ) throws -> VerificationReport {
        var expected: [String: ExpectedFile] = [:]

        func add(_ file: ResolvedFile?) {
            guard let file else { return }
            let key = file.path.standardizedFileURL.path
            if let existing = expected[key] {
                // Keep the strictest expectation when the same path appears twice.
                expected[key] = ExpectedFile(
                    path: file.path,
                    sha1: existing.sha1 ?? file.sha1,
                    size: existing.size ?? file.size
                )
            } else {
                expected[key] = ExpectedFile(path: file.path, sha1: file.sha1, size: file.size)
            }
        }

        add(dependencies.clientJar)
        for file in dependencies.classpathFiles {
            add(file)
        }
        for native in dependencies.legacyNatives {
            add(native.file)
        }
        add(dependencies.assetIndexFile)
        add(dependencies.loggingFile)

        if let assetIndex {
            for object in assetIndex.uniqueObjects() {
                let path = try layout.assetObjectURL(sha1: object.hash)
                expected[path.standardizedFileURL.path] = ExpectedFile(path: path, sha1: object.hash, size: object.size)
            }
        }

        var issues: [VerificationIssue] = []
        var checkedFiles = 0
        var checkedBytes = 0

        for key in expected.keys.sorted() {
            guard let file = expected[key] else { continue }
            checkedFiles += 1

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                issues.append(VerificationIssue(kind: .missing, path: file.path, expected: file.sha1))
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue else {
                issues.append(VerificationIssue(kind: .readError, path: file.path))
                continue
            }
            checkedBytes += size
            if size == 0 {
                issues.append(VerificationIssue(kind: .emptyFile, path: file.path, expected: file.size.map(String.init), actual: "0"))
                continue
            }
            if let expectedSize = file.size, size != expectedSize {
                issues.append(VerificationIssue(
                    kind: .sizeMismatch,
                    path: file.path,
                    expected: String(expectedSize),
                    actual: String(size)
                ))
                continue
            }
            guard let expectedHash = file.sha1 else { continue }
            let actualHash: String
            do {
                actualHash = try SHA1.hexDigest(ofFileAt: file.path)
            } catch {
                issues.append(VerificationIssue(kind: .readError, path: file.path, expected: expectedHash))
                continue
            }
            if actualHash != expectedHash.lowercased() {
                issues.append(VerificationIssue(
                    kind: .hashMismatch,
                    path: file.path,
                    expected: expectedHash.lowercased(),
                    actual: actualHash
                ))
            }
        }

        return VerificationReport(
            versionID: version.id,
            checkedFiles: checkedFiles,
            checkedBytes: checkedBytes,
            issues: issues
        )
    }

    static func loadAssetIndex(layout: GameDataLayout, version: ResolvedVersion) -> AssetIndexDocument? {
        guard let url = try? layout.assetIndexURL(id: version.assetIndexID),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(AssetIndexDocument.self, from: data)
    }

    private struct ExpectedFile {
        let path: URL
        let sha1: String?
        let size: Int?
    }
}
