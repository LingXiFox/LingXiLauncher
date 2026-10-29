import Foundation
import LauncherCore

private struct JSONGraphicsStatus: Encodable {
    struct Mod: Encodable {
        let projectID: String?
        let title: String
        let version: String
        let fileName: String
        let enabled: Bool
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id", title, version
            case fileName = "file_name", enabled
        }
    }
    let instanceID: String
    let gameVersion: String
    let loaderVersion: String?
    let ready: Bool
    let hasUpdate: Bool
    let iris: Mod?
    let sodium: Mod?
    let recommendedIris: String?
    let recommendedSodium: String?
    let warnings: [String]
    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case gameVersion = "game_version"
        case loaderVersion = "loader_version"
        case ready, iris, sodium, warnings
        case hasUpdate = "has_update"
        case recommendedIris = "recommended_iris"
        case recommendedSodium = "recommended_sodium"
    }
}

private struct JSONGraphicsSetup: Encodable {
    let instanceID: String
    let iris: String
    let sodium: String
    let changed: [String]
    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id", iris, sodium, changed
    }
}

private struct JSONShaderSearch: Encodable {
    let totalHits: Int
    let offset: Int
    let limit: Int
    let hits: [JSONShaderHit]
    enum CodingKeys: String, CodingKey { case totalHits = "total_hits", offset, limit, hits }
}

private struct JSONShaderHit: Encodable {
    let projectID: String
    let slug: String?
    let title: String
    let description: String
    let author: String?
    let downloads: Int
    let follows: Int
    let iconURL: String?
    let license: String?
    let versions: [String]
    enum CodingKeys: String, CodingKey {
        case slug, title, description, author, downloads, follows, versions, license
        case projectID = "project_id"
        case iconURL = "icon_url"
    }
}

private struct JSONShaderListEntry: Encodable {
    let projectID: String?
    let title: String
    let version: String?
    let fileName: String
    let source: String
    let enabled: Bool
    let license: String?
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id", title, version
        case fileName = "file_name", source, enabled, license
    }
}

private struct JSONShaderInstall: Encodable {
    let projectID: String?
    let title: String
    let version: String?
    let fileName: String
    let bytes: Int
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id", title, version
        case fileName = "file_name", bytes
    }
}

private struct JSONShaderUpdate: Encodable {
    let projectID: String
    let title: String
    let currentVersion: String?
    let latestVersion: String
    let latestVersionID: String
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id", title
        case currentVersion = "current_version"
        case latestVersion = "latest_version"
        case latestVersionID = "latest_version_id"
    }
}

private struct JSONShaderActivation: Encodable {
    let state: String
    let shaderPack: String?
    let message: String
    enum CodingKeys: String, CodingKey {
        case state, message
        case shaderPack = "shader_pack"
    }
}

extension CLI {
    static func runGraphicsCommand(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing graphics action", suggestion: "Use `lingxi graphics status|setup`.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "status": return try await runGraphicsStatus(rest)
        case "setup": return try await runGraphicsSetup(rest)
        default: throw LauncherError(.usageError, "Unknown graphics action '\(action)'")
        }
    }

    static func runShaderCommand(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing shader action", suggestion: "Use `lingxi shader search|install|list|import|updates|enable|disable|remove`.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "search": return try await runShaderSearch(rest)
        case "install": return try await runShaderInstall(rest)
        case "list": return try runShaderList(rest)
        case "import": return try runShaderImport(rest)
        case "updates": return try await runShaderUpdates(rest)
        case "enable": return try runShaderEnable(rest)
        case "disable": return try runShaderDisable(rest)
        case "remove": return try runShaderRemove(rest)
        default: throw LauncherError(.usageError, "Unknown shader action '\(action)'")
        }
    }

    private static func graphicsManager(_ input: CommandLineInput) throws -> (GraphicsSetupManager, String) {
        let layout = try resolveLayout(input)
        return (GraphicsSetupManager(layout: layout), try input.requireValue("instance"))
    }

    private static func shaderManager(_ input: CommandLineInput) throws -> (ShaderPackManager, String) {
        let layout = try resolveLayout(input)
        return (ShaderPackManager(layout: layout), try input.requireValue("instance"))
    }

    private static func graphicsMod(_ mod: InstalledMod?) -> JSONGraphicsStatus.Mod? {
        guard let mod else { return nil }
        return JSONGraphicsStatus.Mod(
            projectID: mod.projectID,
            title: mod.title,
            version: mod.versionNumber ?? "?",
            fileName: mod.fileName,
            enabled: mod.enabled
        )
    }

    private static func emitGraphicsStatus(_ environment: GraphicsSetupEnvironment, json: Bool) {
        if json {
            CLIOutput.emitJSON(JSONGraphicsStatus(
                instanceID: environment.instanceID,
                gameVersion: environment.gameVersion,
                loaderVersion: environment.loaderVersion,
                ready: environment.isReady,
                hasUpdate: environment.hasUpdate,
                iris: graphicsMod(environment.iris),
                sodium: graphicsMod(environment.sodium),
                recommendedIris: environment.recommendedIris?.versionNumber,
                recommendedSodium: environment.recommendedSodium?.versionNumber,
                warnings: environment.warnings
            ))
        } else {
            CLIOutput.header("Graphics environment")
            CLIOutput.field("instance", environment.instanceID)
            CLIOutput.field("minecraft", environment.gameVersion)
            CLIOutput.field("fabric-loader", environment.loaderVersion ?? "?")
            CLIOutput.field("iris", environment.iris.map { "\($0.versionNumber ?? "?") (\($0.enabled ? "enabled" : "disabled"))" } ?? "not installed")
            CLIOutput.field("sodium", environment.sodium.map { "\($0.versionNumber ?? "?") (\($0.enabled ? "enabled" : "disabled"))" } ?? "not installed")
            CLIOutput.field("recommended-iris", environment.recommendedIris?.versionNumber ?? "?")
            CLIOutput.field("recommended-sodium", environment.recommendedSodium?.versionNumber ?? "?")
            for warning in environment.warnings { print("  warning: \(warning)") }
        }
    }

    private static func runGraphicsStatus(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi graphics status --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try graphicsManager(input)
        let environment = try await manager.environment(instanceID: instanceID)
        emitGraphicsStatus(environment, json: input.has("json"))
        return ExitStatus.success.rawValue
    }

    private static func runGraphicsSetup(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"], flagOptions: ["replace", "json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi graphics setup --instance <id> [--replace] [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try graphicsManager(input)
        let plan = try await manager.plan(instanceID: instanceID)
        if plan.requiresReplacement && !input.has("replace") {
            for note in plan.notes { print("  \(note)") }
            throw LauncherError(
                .usageError,
                "Iris/Sodium 已有不同版本；计划需要替换。",
                suggestion: "确认后使用 `lingxi graphics setup --instance \(instanceID) --replace`。"
            )
        }
        let report = try await manager.install(instanceID: instanceID, allowReplace: input.has("replace")) { progress in
            if progress.completed == 0 || progress.completed == progress.total {
                CLIOutput.fail("[graphics] \(progress.message)")
            }
        }
        if input.has("json") {
            CLIOutput.emitJSON(JSONGraphicsSetup(
                instanceID: instanceID,
                iris: report.installedIris.versionNumber ?? "?",
                sodium: report.installedSodium.versionNumber ?? "?",
                changed: report.changedProjectIDs
            ))
        } else {
            CLIOutput.header("Iris + Sodium ready")
            CLIOutput.field("iris", report.installedIris.versionNumber ?? "?")
            CLIOutput.field("sodium", report.installedSodium.versionNumber ?? "?")
            CLIOutput.field("changed", report.changedProjectIDs.joined(separator: ", "))
        }
        return ExitStatus.success.rawValue
    }

    private static func runShaderSearch(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "query", "category", "sort", "offset", "limit", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi shader search --instance <id> [--query <text>] [--category a,b] [--sort relevance|downloads|follows|newest|updated] [--offset 0] [--limit 20] [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try shaderManager(input)
        let sort: ModrinthSort
        if let raw = input.value("sort") {
            guard let parsed = ModrinthSort(rawValue: raw) else {
                throw LauncherError(.usageError, "Unknown shader sort '\(raw)'")
            }
            sort = parsed
        } else {
            sort = .relevance
        }
        let categories = (input.value("category") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let result = try await manager.search(
            instanceID: instanceID,
            query: input.value("query") ?? "",
            categories: categories,
            sort: sort,
            offset: Int(input.value("offset") ?? "0") ?? 0,
            limit: Int(input.value("limit") ?? "20") ?? 20
        )
        if input.has("json") {
            CLIOutput.emitJSON(JSONShaderSearch(
                totalHits: result.totalHits,
                offset: result.offset,
                limit: result.limit,
                hits: result.hits.map {
                    JSONShaderHit(
                        projectID: $0.projectID, slug: $0.slug, title: $0.title,
                        description: $0.description, author: $0.author,
                        downloads: $0.downloads, follows: $0.follows,
                        iconURL: $0.iconURL, license: $0.license, versions: $0.versions
                    )
                }
            ))
        } else {
            CLIOutput.header("Shader packs (\(result.totalHits) results)")
            for hit in result.hits {
                print("  \(hit.title)  [\(hit.projectID)]  \(hit.downloads) downloads")
                print("    \(hit.description)")
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func runShaderInstall(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "project", "version", "replace", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi shader install --instance <id> --project <id|slug> [--version <version-id>] [--replace <old-file>] [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try shaderManager(input)
        let report = try await manager.install(
            instanceID: instanceID,
            projectIDOrSlug: try input.requireValue("project"),
            versionID: input.value("version"),
            replacingFileName: input.value("replace")
        ) { progress in
            if progress.phase != .downloading || progress.completed == progress.total {
                CLIOutput.fail("[shader] \(progress.message)")
            }
        }
        if input.has("json") {
            CLIOutput.emitJSON(JSONShaderInstall(
                projectID: report.installed.projectID,
                title: report.installed.title,
                version: report.installed.versionNumber,
                fileName: report.installed.fileName,
                bytes: report.downloadedBytes
            ))
        } else {
            CLIOutput.header("Shader pack installed")
            CLIOutput.field("title", report.installed.title)
            CLIOutput.field("version", report.installed.versionNumber ?? "?")
            CLIOutput.field("file", report.installed.fileName)
            CLIOutput.field("size", Downloader.format(bytes: report.downloadedBytes))
            print("  It is installed but not enabled; use `lingxi shader enable`.")
        }
        return ExitStatus.success.rawValue
    }

    private static func runShaderList(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi shader list --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try shaderManager(input)
        let packs = try manager.installed(instanceID: instanceID)
        let activation = try manager.activationState(instanceID: instanceID)
        if input.has("json") {
            CLIOutput.emitJSON(packs.map {
                JSONShaderListEntry(
                    projectID: $0.projectID, title: $0.title, version: $0.versionNumber,
                    fileName: $0.fileName, source: $0.source.rawValue,
                    enabled: activation.shaderPack == $0.title && activation.kind == .enabled,
                    license: $0.license
                )
            })
        } else {
            CLIOutput.header("Shader packs (\(packs.count))")
            for pack in packs {
                let active = activation.shaderPack == pack.title && activation.kind == .enabled
                print("  \(active ? "[on] " : "[off]") \(pack.fileName)  \(pack.versionNumber ?? pack.source.rawValue)")
            }
            CLIOutput.field("iris", activation.message)
        }
        return ExitStatus.success.rawValue
    }

    private static func runShaderImport(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "file", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi shader import --instance <id> --file <pack.zip> [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try shaderManager(input)
        let file = URL(fileURLWithPath: (try input.requireValue("file") as NSString).expandingTildeInPath).standardizedFileURL
        let report = try manager.importLocal(archiveURL: file, instanceID: instanceID) { progress in
            CLIOutput.fail("[shader] \(progress.message)")
        }
        if input.has("json") {
            CLIOutput.emitJSON(JSONShaderInstall(
                projectID: report.installed.projectID,
                title: report.installed.title,
                version: report.installed.versionNumber,
                fileName: report.installed.fileName,
                bytes: report.downloadedBytes
            ))
        } else {
            CLIOutput.header("Local shader pack imported")
            CLIOutput.field("file", report.installed.fileName)
            print("  It is installed but not enabled; use `lingxi shader enable`.")
        }
        return ExitStatus.success.rawValue
    }

    private static func runShaderUpdates(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi shader updates --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try shaderManager(input)
        let updates = try await manager.updates(instanceID: instanceID)
        if input.has("json") {
            CLIOutput.emitJSON(updates.map {
                JSONShaderUpdate(
                    projectID: $0.projectID, title: $0.title,
                    currentVersion: $0.currentVersionNumber,
                    latestVersion: $0.latestVersionNumber,
                    latestVersionID: $0.latestVersionID
                )
            })
        } else {
            CLIOutput.header("Shader updates (\(updates.count))")
            for update in updates {
                print("  \(update.title): \(update.currentVersionNumber ?? "?") -> \(update.latestVersionNumber)")
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func runShaderEnable(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "file", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi shader enable --instance <id> --file <pack.zip> [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try shaderManager(input)
        let result = try manager.activate(
            fileName: try input.requireValue("file"),
            instanceID: instanceID
        )
        if input.has("json") {
            CLIOutput.emitJSON(JSONShaderActivation(state: "enabled", shaderPack: result.shaderPack, message: result.message))
        } else {
            CLIOutput.header("Iris shader enabled")
            CLIOutput.field("pack", result.shaderPack)
            CLIOutput.field("config", result.configURL.path)
            if let backup = result.backupURL { CLIOutput.field("backup", backup.path) }
        }
        return ExitStatus.success.rawValue
    }

    private static func runShaderDisable(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi shader disable --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try shaderManager(input)
        let result = try manager.deactivate(instanceID: instanceID)
        if input.has("json") {
            CLIOutput.emitJSON(JSONShaderActivation(state: "disabled", shaderPack: nil, message: result.message))
        } else {
            CLIOutput.header("Iris shaders disabled")
            CLIOutput.field("config", result.configURL.path)
        }
        return ExitStatus.success.rawValue
    }

    private static func runShaderRemove(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "file", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi shader remove --instance <id> --file <pack.zip>")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try shaderManager(input)
        try manager.remove(fileName: try input.requireValue("file"), instanceID: instanceID)
        CLIOutput.header("Shader pack removed")
        return ExitStatus.success.rawValue
    }
}
