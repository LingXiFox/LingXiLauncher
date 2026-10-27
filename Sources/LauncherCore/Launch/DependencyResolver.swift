import Foundation

/// Maps rule-allowed libraries, legacy natives and asset/logging metadata onto local URLs and
/// reports which of those files are missing.
///
/// M1 scope: the resolver only *stats* files against the metadata (existence, empty file, size).
/// It never downloads, never hashes and never creates directories. An absent file is reported only
/// as a `MissingDependency` carrying the download metadata M2 needs; `LaunchPlanBuilder.validate()`
/// escalates those into blocking errors. `diagnostics` is reserved for structural problems
/// (unresolvable metadata paths, legacy x86_64 natives on Apple Silicon, legacy assets metadata).
/// Legacy natives whose architecture is unknown produce a single advisory warning on arm64.
///
/// Ordering rules:
/// - Libraries are kept in metadata order; disallowed libraries are skipped entirely.
/// - Classpath entries are de-duplicated by their standardized path, first occurrence wins. The
///   client JAR is appended exactly once and is always the final classpath entry.
/// - Legacy `natives` + `downloads.classifiers` are the only source of `ResolvedNative` entries.
///   Modern versions ship native JARs as ordinary `natives-*` libraries on the classpath.
/// - Every join goes through `GameDataLayout`/`PathSafety`, so `PATH_ESCAPES_ROOT` propagates.
public struct DependencyResolver: DependencyResolving {
    private let ruleEvaluator: any RuleEvaluating

    /// - Parameter ruleEvaluator: Evaluates `libraries[].rules`. Injected so there is exactly one
    ///   platform-matching policy in the launcher and this type stays testable in isolation.
    public init(ruleEvaluator: any RuleEvaluating) {
        self.ruleEvaluator = ruleEvaluator
    }

    public func resolve(
        version: ResolvedVersion,
        layout: GameDataLayout,
        platform: PlatformContext
    ) throws -> DependencyResolution {
        // Computed even when no legacy natives exist: it is part of the resolution contract and
        // the launch plan substitutes it into `${natives_directory}`.
        let nativesDirectory = try layout.nativesDirectory(versionID: version.nativesVersionID, architecture: platform.architecture)

        var classpath: [URL] = []
        var classpathFiles: [ResolvedFile] = []
        var classpathPaths: Set<String> = []
        var legacyNatives: [ResolvedNative] = []
        var missing: [MissingDependency] = []
        var reportedMissing: Set<String> = []
        var diagnostics: [LaunchDiagnostic] = []
        var emittedUnknownNativeArchitectureWarning = false

        for library in version.libraries {
            guard try ruleEvaluator.isAllowed(library.rules, platform: platform) else { continue }

            // 1. The main artifact belongs on the classpath, even for libraries that also declare
            //    legacy natives: the native JAR is extracted, the main JAR must still be loadable.
            if let relativePath = library.artifactRelativePath {
                let url = try layout.libraryURL(relativePath: relativePath)
                let file = resolvedFile(at: url, artifact: library.effectiveArtifact)
                appendClasspath(file, classpath: &classpath, files: &classpathFiles, seen: &classpathPaths)
                recordMissing(file, kind: .library, missing: &missing, reported: &reportedMissing)
            } else {
                diagnostics.append(.error(
                    .invalidMetadata,
                    "Library '\(library.name)' has neither downloads.artifact.path nor a parsable Maven name",
                    suggestion: "Fix or reinstall the version metadata; the launcher cannot locate this library."
                ))
            }

            // 2. Legacy natives: only `natives[os]` + `downloads.classifiers` produce extraction
            //    work. Modern `natives-*` libraries have no `natives` map and fall through here.
            guard let classifierName = library.natives?[platform.os.rawValue] else { continue }

            guard let classifier = library.classifiers?[classifierName] else {
                diagnostics.append(.error(
                    .invalidMetadata,
                    "Library '\(library.name)' declares native classifier '\(classifierName)' for \(platform.os.rawValue) but downloads.classifiers does not contain it",
                    suggestion: "The version metadata is incomplete or corrupt; reinstall the version JSON."
                ))
                continue
            }

            guard let classifierPath = Self.relativePath(for: classifier, classifier: classifierName, coordinates: library.coordinates) else {
                diagnostics.append(.error(
                    .invalidMetadata,
                    "Native classifier '\(classifierName)' of library '\(library.name)' has neither a path nor a parsable Maven name",
                    suggestion: "The launcher cannot locate this native archive; reinstall the version JSON."
                ))
                continue
            }

            let nativeURL = try layout.libraryURL(relativePath: classifierPath)
            let nativeFile = resolvedFile(at: nativeURL, artifact: classifier)
            let architectureHint = Self.architectureHint(forClassifier: classifierName)
            legacyNatives.append(ResolvedNative(
                classifier: classifierName,
                file: nativeFile,
                extractExclude: library.extractExclude ?? [],
                architectureHint: architectureHint
            ))

            if architectureHint == .x86_64, platform.architecture == .arm64 {
                diagnostics.append(.error(
                    .javaArchitectureMismatch,
                    "Native classifier '\(classifierName)' of library '\(library.name)' contains x86_64 native libraries, but this launch targets arm64. An arm64 JVM cannot load x86_64 native libraries.",
                    suggestion: "This legacy version needs an explicit compatibility decision: run it with an x86_64 Java runtime under Rosetta, or use a version that ships natives-macos-arm64."
                ))
            } else if architectureHint == nil, platform.architecture == .arm64, !emittedUnknownNativeArchitectureWarning {
                // We cannot statically prove the archive is x86_64-only, so this is advisory, not
                // blocking. Emit it once per resolution: every 1.16-style native would otherwise
                // produce an identical line.
                emittedUnknownNativeArchitectureWarning = true
                diagnostics.append(.warning(
                    .javaArchitectureMismatch,
                    "Native archive '\(classifierName)' of library '\(library.name)' does not declare its CPU architecture; on Apple Silicon this legacy archive may contain x86_64-only libraries",
                    suggestion: "Verify it on this Mac or run the version with an x86_64 Java under Rosetta; LingXi never auto-fixes mixed architectures."
                ))
            }

            recordMissing(nativeFile, kind: .native, missing: &missing, reported: &reportedMissing)
        }

        // 3. The client JAR is required and always the last classpath entry. It is appended even
        //    when the metadata omits `downloads.client`; the missing entry then carries no download
        //    metadata, and the plan builder blocks the launch based on the empty file list.
        let clientJarURL = try layout.clientJarURL(version.clientJarVersionID)
        let clientJar = resolvedFile(at: clientJarURL, artifact: version.clientJar)
        if let existing = classpath.firstIndex(where: { Self.samePath($0, clientJarURL) }) {
            classpath.remove(at: existing)
            if existing < classpathFiles.count {
                classpathFiles.remove(at: existing)
            }
        }
        classpath.append(clientJarURL)
        classpathFiles.append(clientJar)
        recordMissing(clientJar, kind: .clientJar, missing: &missing, reported: &reportedMissing)

        // 4. Asset index. Legacy metadata has no assetIndex: the game uses its legacy assets id
        //    and the launcher cannot verify assets, so that is a warning rather than a missing file.
        var assetIndexFile: ResolvedFile?
        if let assetIndex = version.assetIndex {
            let url = try layout.assetIndexURL(id: version.assetIndexID)
            let file = ResolvedFile(path: url, sha1: assetIndex.sha1, size: assetIndex.size, downloadURL: assetIndex.url)
            assetIndexFile = file
            recordMissing(file, kind: .assetIndex, missing: &missing, reported: &reportedMissing)
        } else {
            diagnostics.append(LaunchDiagnostic(
                severity: .warning,
                message: "Version \(version.id) has no assetIndex; asset verification is limited to the legacy assets id '\(version.assetIndexID)'",
                suggestion: "Legacy assets are not verified in M1; the game still needs them installed to render correctly."
            ))
        }

        // 5. Logging configuration (`assets/log_configs/<name>`).
        var loggingFile: ResolvedFile?
        if let logging = version.clientLogging {
            // `preferredFileName` uses Mojang's explicit `id` first, then the path or URL basename.
            if let identifier = logging.file.preferredFileName {
                let url = try layout.loggingConfigURL(id: identifier)
                let file = ResolvedFile(path: url, sha1: logging.file.sha1, size: logging.file.size, downloadURL: logging.file.url)
                loggingFile = file
                recordMissing(file, kind: .loggingConfig, missing: &missing, reported: &reportedMissing)
            } else {
                diagnostics.append(LaunchDiagnostic(
                    severity: .warning,
                    code: .invalidMetadata,
                    message: "Logging metadata for version \(version.id) has no id, path or download URL to derive the log configuration file name from",
                    suggestion: "The launch plan will omit the log4j configuration file; reinstall the version JSON to restore it."
                ))
            }
        }

        return DependencyResolution(
            layout: layout,
            classpath: classpath,
            classpathFiles: classpathFiles,
            legacyNatives: legacyNatives,
            nativesDirectory: nativesDirectory,
            clientJar: clientJar,
            assetIndexFile: assetIndexFile,
            loggingFile: loggingFile,
            missing: missing,
            diagnostics: diagnostics
        )
    }

    // MARK: - Resolved files

    private func resolvedFile(at url: URL, artifact: Artifact?) -> ResolvedFile {
        ResolvedFile(
            path: url,
            sha1: artifact?.sha1,
            size: artifact?.size,
            downloadURL: artifact?.url
        )
    }

    private func appendClasspath(
        _ file: ResolvedFile,
        classpath: inout [URL],
        files: inout [ResolvedFile],
        seen: inout Set<String>
    ) {
        guard seen.insert(Self.standardizedKey(file.path)).inserted else { return }
        classpath.append(file.path)
        files.append(file)
    }

    // MARK: - Local file inspection

    /// Records a missing file once per kind+path.
    ///
    /// `diagnostics` deliberately stays reserved for structural problems: an absent file is only a
    /// `MissingDependency`, which `LaunchPlanBuilder.validate()` already turns into a blocking
    /// error. Emitting a diagnostic here too would duplicate the message in `--dry-run`/`doctor`.
    private func recordMissing(
        _ file: ResolvedFile,
        kind: MissingDependency.Kind,
        missing: inout [MissingDependency],
        reported: inout Set<String>
    ) {
        guard let reason = Self.localFileIssue(file) else { return }

        let key = "\(kind.rawValue)|\(Self.standardizedKey(file.path))"
        guard reported.insert(key).inserted else { return }

        missing.append(MissingDependency(
            kind: kind,
            path: file.path,
            reason: reason,
            downloadURL: file.downloadURL,
            sha1: file.sha1,
            size: file.size
        ))
    }

    /// Existence/size-only inspection. Hashing is intentionally M2 and directories never count as
    /// a usable file.
    private static func localFileIssue(_ file: ResolvedFile) -> MissingDependency.Reason? {
        let path = file.path.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .absent
        }
        guard !isDirectory.boolValue else { return .absent }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return .absent
        }
        if size == 0 { return .emptyFile }
        if let expected = file.size, size != expected { return .sizeMismatch }
        return nil
    }

    // MARK: - Paths

    private static func standardizedKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        standardizedKey(lhs) == standardizedKey(rhs)
    }

    /// Relative path for a native classifier JAR: the metadata `path` wins, Maven layout with the
    /// classifier appended is the fallback.
    private static func relativePath(for artifact: Artifact, classifier: String, coordinates: MavenCoordinates?) -> String? {
        if let path = artifact.path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        guard let coordinates else { return nil }
        let groupPath = coordinates.group.replacingOccurrences(of: ".", with: "/")
        return "\(groupPath)/\(coordinates.artifact)/\(coordinates.version)/\(coordinates.artifact)-\(coordinates.version)-\(classifier).jar"
    }

    /// Best-effort architecture hint from a legacy classifier name. Plain `natives-macos` /
    /// `natives-osx` archives are architecture-neutral (universal or resolved by the JVM) and get
    /// no hint; only explicit x64 suffixes are reported so they can be flagged on Apple Silicon.
    private static func architectureHint(forClassifier classifier: String) -> PlatformContext.CPUArch? {
        let lowered = classifier.lowercased()
        if lowered.hasSuffix("-arm64") || lowered.hasSuffix("-aarch64") { return .arm64 }
        if lowered.hasSuffix("-x86_64") || lowered.hasSuffix("-x64") { return .x86_64 }
        return nil
    }
}
