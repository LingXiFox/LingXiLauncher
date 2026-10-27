import Foundation

/// Reads per-version JSON files from a game root and merges `inheritsFrom` chains into one
/// structural `ResolvedVersion`.
///
/// Merge policy (parent → child):
/// - `mainClass`, type, assets/assetIndex, logging and downloads are inherited; the child wins
///   when it supplies a non-empty value.
/// - `libraries` are merged in parent order. A child library overrides the parent entry with the
///   same Maven group/artifact/classifier, so loader-pinned ASM versions replace vanilla ones.
/// - `arguments.jvm` / `arguments.game` are concatenated as structured entries (never as one
///   shell string); child entries append after the inherited entries.
/// - Java requirements take the highest required major version in the chain.
/// - Legacy `minecraftArguments` is converted to structured game arguments and gets the legacy
///   JVM baseline. Such versions are marked `.legacyArguments`, never `.modern`.
public struct VersionResolver: VersionResolving {
    public init() {}

    public func resolve(versionID: String, from root: URL) throws -> ResolvedVersion {
        let layout = GameDataLayout(gameRoot: root)
        let chain = try loadChain(versionID: versionID, layout: layout, stack: [])
        guard let child = chain.last else {
            throw LauncherError(.invalidMetadata, "Version chain for \(versionID) is empty")
        }
        return try normalize(
            chain: chain,
            requestedID: versionID,
            versionDirectory: try layout.versionDirectory(versionID),
            metadataURL: try layout.versionJSONURL(versionID),
            child: child
        )
    }

    /// Normalises an already-decoded metadata document without a parent chain. Callers that have
    /// an `inheritsFrom` value must use `resolve(versionID:from:)` so the parent can be loaded.
    public func resolve(
        metadata: VersionMetadata,
        versionID: String,
        versionDirectory: URL,
        metadataURL: URL
    ) throws -> ResolvedVersion {
        if let parent = metadata.inheritsFrom, !parent.isEmpty {
            throw LauncherError(
                .missingDependency,
                "Version \(versionID) inherits from '\(parent)' but no parent chain was supplied",
                suggestion: "Resolve from a game root containing versions/\(parent)/\(parent).json."
            )
        }
        guard metadata.id == versionID else {
            throw LauncherError(
                .invalidMetadata,
                "Version JSON id '\(metadata.id)' does not match requested version '\(versionID)'",
                suggestion: "The metadata file is misplaced or corrupted; reinstall the version metadata."
            )
        }
        return try normalize(
            chain: [metadata],
            requestedID: versionID,
            versionDirectory: versionDirectory,
            metadataURL: metadataURL,
            child: metadata
        )
    }

    // MARK: - Chain loading

    private func loadChain(versionID: String, layout: GameDataLayout, stack: [String]) throws -> [VersionMetadata] {
        guard stack.count < 16 else {
            throw LauncherError(
                .unsupportedVersion,
                "Version inheritance chain is deeper than 16 entries at '\(versionID)'",
                suggestion: "This metadata is likely malformed; reinstall the version profile."
            )
        }
        guard !stack.contains(versionID) else {
            let cycle = (stack + [versionID]).joined(separator: " → ")
            throw LauncherError(
                .invalidMetadata,
                "Circular version inheritance: \(cycle)",
                suggestion: "Remove the cycle from the version JSON files."
            )
        }

        let jsonURL = try layout.versionJSONURL(versionID)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw LauncherError(
                .missingDependency,
                "Version metadata not found: \(jsonURL.path)",
                suggestion: "Download the version metadata first, or install its parent version."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(jsonURL.path): \(error.localizedDescription)")
        }
        let metadata = try VersionMetadata.decode(from: data, context: "versions/\(versionID)/\(versionID).json")
        guard metadata.id == versionID else {
            throw LauncherError(.invalidMetadata, "Version JSON id '\(metadata.id)' does not match requested version '\(versionID)'")
        }

        if let parent = metadata.inheritsFrom?.trimmingCharacters(in: .whitespacesAndNewlines), !parent.isEmpty {
            var chain = try loadChain(versionID: parent, layout: layout, stack: stack + [versionID])
            chain.append(metadata)
            return chain
        }
        return [metadata]
    }

    // MARK: - Merge / normalise

    private func normalize(
        chain: [VersionMetadata],
        requestedID: String,
        versionDirectory: URL,
        metadataURL: URL,
        child: VersionMetadata
    ) throws -> ResolvedVersion {
        let mainClass = chain.reversed().first(where: { !$0.mainClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.mainClass
        guard let mainClass else {
            throw LauncherError(.invalidMetadata, "Version \(requestedID) declares an empty mainClass")
        }

        let assetIndex = chain.reversed().compactMap(\.assetIndex).first
        let assets = chain.reversed().compactMap(\.assets).first
        guard let assetIndexID = assetIndex?.id ?? assets, !assetIndexID.isEmpty else {
            throw LauncherError(
                .invalidMetadata,
                "Version \(requestedID) has no assetIndex and no assets id",
                suggestion: "The metadata cannot be launched without an asset index reference."
            )
        }

        let javaRequirement = mergedJavaRequirement(chain)
        let libraries = mergedLibraries(chain)
        let arguments = mergedArguments(chain)
        guard !arguments.game.isEmpty else {
            throw LauncherError(
                .invalidMetadata,
                "Version \(requestedID) declares no game arguments after inheritance",
                suggestion: "The version JSON is incomplete or not a Minecraft client profile."
            )
        }

        let clientJarInfo = chain.reversed().compactMap { metadata -> (String, Artifact)? in
            guard let client = metadata.downloads?.client else { return nil }
            return (metadata.id, client)
        }.first
        let clientJarVersionID = clientJarInfo?.0 ?? requestedID

        let type = chain.reversed().compactMap(\.type).first ?? "unknown"
        let logging = chain.reversed().compactMap(\.logging).first
        let releaseTime = chain.reversed().compactMap(\.releaseTime).first
        let inheritedFrom = child.inheritsFrom

        return ResolvedVersion(
            id: requestedID,
            type: type,
            mainClass: mainClass,
            assetIndexID: assetIndexID,
            javaRequirement: javaRequirement,
            libraries: libraries,
            jvmArguments: arguments.jvm,
            gameArguments: arguments.game,
            defaultUserJVMArguments: arguments.defaultUser,
            assetIndex: assetIndex,
            clientLogging: logging?.client,
            clientJar: clientJarInfo?.1,
            clientJarVersionID: clientJarVersionID,
            nativesVersionID: clientJarVersionID,
            inheritsFrom: inheritedFrom,
            compatibility: arguments.compatibility,
            versionDirectory: versionDirectory,
            metadataURL: metadataURL,
            releaseTime: releaseTime
        )
    }

    private func mergedJavaRequirement(_ chain: [VersionMetadata]) -> JavaVersionRequirement {
        var component: String?
        var major: Int?
        for metadata in chain {
            guard let requirement = metadata.javaVersion else { continue }
            if major == nil || (requirement.majorVersion ?? 0) >= (major ?? 0) {
                if let value = requirement.majorVersion { major = value }
                if let value = requirement.component { component = value }
            }
        }
        return JavaVersionRequirement(component: component, majorVersion: major)
    }

    /// Parent order, child override by Maven identity. Keeping the position stable preserves the
    /// official classpath prefix while still allowing Fabric to replace a vanilla library version.
    private func mergedLibraries(_ chain: [VersionMetadata]) -> [Library] {
        var result: [Library] = []
        var index: [String: Int] = [:]
        for metadata in chain {
            for library in metadata.libraries {
                let key = Self.libraryKey(library)
                if let existing = index[key] {
                    result[existing] = library
                } else {
                    index[key] = result.count
                    result.append(library)
                }
            }
        }
        return result
    }

    private func mergedArguments(_ chain: [VersionMetadata]) -> (
        jvm: [ArgumentEntry],
        game: [ArgumentEntry],
        defaultUser: [ArgumentEntry],
        compatibility: VersionCompatibility
    ) {
        var jvm: [ArgumentEntry] = []
        var game: [ArgumentEntry] = []
        var defaultUser: [ArgumentEntry] = []
        for metadata in chain {
            if let arguments = metadata.arguments {
                jvm.append(contentsOf: arguments.jvm)
                game.append(contentsOf: arguments.game)
                defaultUser.append(contentsOf: arguments.defaultUserJVMArguments)
            }
        }

        var compatibility: VersionCompatibility = .modern
        let legacyString = chain.reversed().compactMap(\.minecraftArguments).first(where: { !$0.isEmpty })
        if game.isEmpty, let legacyString {
            game = Self.parseLegacyArguments(legacyString)
            compatibility = .legacyArguments
        }
        if jvm.isEmpty {
            jvm = Self.legacyJVMArguments
            if compatibility == .modern {
                compatibility = .incomplete
            }
        }
        return (jvm, game, defaultUser, compatibility)
    }

    private static func libraryKey(_ library: Library) -> String {
        let base: String
        if let coordinates = library.coordinates {
            base = "\(coordinates.group):\(coordinates.artifact):\(coordinates.classifier ?? "")"
        } else {
            base = library.name
        }
        // Legacy 1.16.5 profiles contain two entries with the same Maven name: one normal
        // artifact and one carrying a `natives` map. They are not duplicates. Include the
        // native/classifier identity so inheritance merging never collapses them.
        let natives = (library.natives ?? [:])
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
        let classifiers = (library.classifiers ?? [:])
            .keys
            .sorted()
            .joined(separator: ",")
        let extract = (library.extractExclude ?? []).sorted().joined(separator: ",")
        return "\(base)|natives=\(natives)|classifiers=\(classifiers)|extract=\(extract)"
    }

    /// Legacy Minecraft arguments are a whitespace-separated string. Keep quoted values and
    /// placeholders intact; expansion remains the ArgumentResolver's job.
    static func parseLegacyArguments(_ raw: String) -> [ArgumentEntry] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in raw {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.map(ArgumentEntry.argument)
    }

    /// Baseline for pre-1.13 profiles. Modern metadata supplies its own JVM arguments; this is
    /// only used when the whole chain is legacy (or is structurally incomplete).
    static let legacyJVMArguments: [ArgumentEntry] = [
        .argument("-Djava.library.path=${natives_directory}"),
        .argument("-Dminecraft.launcher.brand=${launcher_name}"),
        .argument("-Dminecraft.launcher.version=${launcher_version}"),
        .argument("-cp"),
        .argument("${classpath}"),
    ]
}
