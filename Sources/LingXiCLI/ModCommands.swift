import Foundation
import LauncherCore

private struct JSONModSearch: Encodable {
    let totalHits: Int
    let offset: Int
    let limit: Int
    let hits: [JSONModHit]
    enum CodingKeys: String, CodingKey { case totalHits = "total_hits", offset, limit, hits }
}
private struct JSONModHit: Encodable {
    let projectID: String
    let slug: String
    let title: String
    let description: String
    let author: String
    let downloads: Int
    enum CodingKeys: String, CodingKey { case projectID = "project_id", slug, title, description, author, downloads }
}
private struct JSONModInstall: Encodable {
    struct Installed: Encodable {
        let projectID: String
        let file: String
        let version: String
        enum CodingKeys: String, CodingKey { case projectID = "project_id", file, version }
    }
    let projectID: String
    let file: String
    let version: String
    let installed: [Installed]
    let optionalDependencies: [String]
    let embeddedDependencies: [String]
    let alreadyInstalledDependencies: [String]
    let downloadedFiles: Int
    let downloadedBytes: Int
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id", file, version, installed
        case optionalDependencies = "optional_dependencies"
        case embeddedDependencies = "embedded_dependencies"
        case alreadyInstalledDependencies = "already_installed_dependencies"
        case downloadedFiles = "downloaded_files", downloadedBytes = "downloaded_bytes"
    }
}
private struct JSONModListEntry: Encodable {
    let projectID: String
    let title: String
    let file: String
    let version: String
    let enabled: Bool
    let source: String
    let license: String
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id", title, file, version, enabled, source, license
    }
}
private struct JSONModUpdate: Encodable {
    let projectID: String
    let title: String
    let currentVersion: String
    let latestVersion: String
    let latestVersionID: String
    let file: String
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id", title
        case currentVersion = "current_version"
        case latestVersion = "latest_version"
        case latestVersionID = "latest_version_id"
        case file
    }
}

extension CLI {
    static func runModCommand(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing mod action", suggestion: "Use `lingxi mod search|install|list|enable|disable|remove|updates`.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "search": return try await runModSearch(rest)
        case "install": return try await runModInstall(rest)
        case "list": return try runModList(rest)
        case "enable": return try runModState(rest, enabled: true)
        case "disable": return try runModState(rest, enabled: false)
        case "remove": return try runModRemove(rest)
        case "updates": return try await runModUpdates(rest)
        default: throw LauncherError(.usageError, "Unknown mod action '\(action)'")
        }
    }

    private static func modManager(_ input: CommandLineInput) throws -> (ModManager, String) {
        let layout = try resolveLayout(input)
        return (ModManager(layout: layout), try input.requireValue("instance"))
    }

    private static func runModSearch(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(
            valueOptions: ["instance", "query", "category", "sort", "offset", "limit", "root", "data-root"],
            flagOptions: ["json", "help"]
        )
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi mod search --instance <id> [--query <text>] [--category a,b] [--sort relevance|downloads|follows|newest|updated] [--offset 0] [--limit 20] [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try modManager(input)
        let categories = (input.value("category") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let sort = ModrinthSort(rawValue: input.value("sort") ?? "relevance") ?? .relevance
        let result = try await manager.search(
            instanceID: instanceID,
            query: input.value("query") ?? "",
            categories: categories,
            sort: sort,
            offset: Int(input.value("offset") ?? "0") ?? 0,
            limit: Int(input.value("limit") ?? "20") ?? 20
        )
        if input.has("json") {
            CLIOutput.emitJSON(JSONModSearch(
                totalHits: result.totalHits,
                offset: result.offset,
                limit: result.limit,
                hits: result.hits.map {
                    JSONModHit(projectID: $0.projectID, slug: $0.slug ?? "", title: $0.title, description: $0.description, author: $0.author ?? "", downloads: $0.downloads)
                }
            ))
        } else {
            CLIOutput.header("Modrinth mods (\(result.totalHits) results)")
            for hit in result.hits {
                print("  \(hit.title.padding(toLength: 28, withPad: " ", startingAt: 0)) \(hit.projectID)  \(hit.downloads) downloads")
                print("    \(hit.description)")
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func runModInstall(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(
            valueOptions: ["instance", "project", "version", "root", "data-root"],
            flagOptions: ["replace", "json", "help"]
        )
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi mod install --instance <id> --project <id|slug> [--version <version-id>] [--replace] [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try modManager(input)
        let request = ModInstallRequest(
            instanceID: instanceID,
            projectIDOrSlug: try input.requireValue("project"),
            versionID: input.value("version"),
            allowReplace: input.has("replace")
        )
        let report = try await manager.install(request) { event in
            CLIOutput.fail("[mod] \(event.message) (\(event.completed)/\(event.total))")
        }
        if input.has("json") {
            CLIOutput.emitJSON(JSONModInstall(
                projectID: report.primary.projectID ?? "",
                file: report.primary.fileName,
                version: report.primary.versionNumber ?? "",
                installed: report.installed.map {
                    JSONModInstall.Installed(projectID: $0.projectID ?? "", file: $0.fileName, version: $0.versionNumber ?? "")
                },
                optionalDependencies: report.optionalDependencies.map(\.projectID),
                embeddedDependencies: report.embeddedDependencies.map(\.projectID),
                alreadyInstalledDependencies: report.alreadyInstalledDependencies,
                downloadedFiles: report.downloadedFiles,
                downloadedBytes: report.downloadedBytes
            ))
        } else {
            CLIOutput.header("Mod installed")
            CLIOutput.field("project", report.primary.title)
            CLIOutput.field("version", report.primary.versionNumber ?? "?")
            CLIOutput.field("file", report.primary.fileName)
            CLIOutput.field("dependencies", "\(report.installed.count - 1) installed, \(report.alreadyInstalledDependencies.count) already present")
            CLIOutput.field("downloaded", "\(report.downloadedFiles) file(s), \(Downloader.format(bytes: report.downloadedBytes))")
            if !report.optionalDependencies.isEmpty {
                CLIOutput.field("optional", report.optionalDependencies.map(\.projectID).joined(separator: ", "))
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func runModList(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi mod list --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try modManager(input)
        let mods = try manager.installed(instanceID: instanceID)
        if input.has("json") {
            CLIOutput.emitJSON(mods.map {
                JSONModListEntry(projectID: $0.projectID ?? "", title: $0.title, file: $0.fileName,
                                 version: $0.versionNumber ?? "", enabled: $0.enabled, source: $0.source,
                                 license: $0.license ?? "")
            })
        } else {
            CLIOutput.header("Installed mods (\(mods.count))")
            for mod in mods {
                print("  \(mod.enabled ? "[on] " : "[off]") \(mod.fileName)  \(mod.versionNumber ?? mod.source)")
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func runModState(_ arguments: [String], enabled: Bool) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "file", "root", "data-root"], flagOptions: ["help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi mod \(enabled ? "enable" : "disable") --instance <id> --file <mod.jar>")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try modManager(input)
        let mod = try manager.setEnabled(enabled, fileName: try input.requireValue("file"), instanceID: instanceID)
        print("\(mod.fileName): \(mod.enabled ? "enabled" : "disabled")")
        return ExitStatus.success.rawValue
    }

    private static func runModRemove(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "file", "root", "data-root"], flagOptions: ["help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi mod remove --instance <id> --file <mod.jar>")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try modManager(input)
        try manager.remove(fileName: try input.requireValue("file"), instanceID: instanceID)
        print("removed \(try input.requireValue("file"))")
        return ExitStatus.success.rawValue
    }

    private static func runModUpdates(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi mod updates --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (manager, instanceID) = try modManager(input)
        let updates = try await manager.updates(instanceID: instanceID)
        if input.has("json") {
            CLIOutput.emitJSON(updates.map {
                JSONModUpdate(projectID: $0.projectID, title: $0.title,
                              currentVersion: $0.currentVersionNumber ?? $0.currentVersionID ?? "",
                              latestVersion: $0.latestVersionNumber, latestVersionID: $0.latestVersionID,
                              file: $0.latestFile.filename)
            })
        } else {
            CLIOutput.header("Mod updates (\(updates.count))")
            for update in updates {
                print("  \(update.title): \(update.currentVersionNumber ?? "?") -> \(update.latestVersionNumber)  [\(update.latestVersionID)]")
            }
        }
        return ExitStatus.success.rawValue
    }
}
