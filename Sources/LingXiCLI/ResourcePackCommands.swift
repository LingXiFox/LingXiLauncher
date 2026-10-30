import Foundation
import LauncherCore

private struct JSONResourcePack: Encodable {
    let fileName: String
    let title: String
    let projectID: String?
    let versionID: String?
    let version: String?
    let source: String
    let enabled: Bool
    let bytes: Int
    enum CodingKeys: String, CodingKey {
        case title, source, enabled, bytes
        case fileName = "file_name"
        case projectID = "project_id"
        case versionID = "version_id"
        case version
    }
}

private struct JSONResourcePackHit: Encodable {
    let projectID: String
    let title: String
    let description: String
    let author: String?
    let downloads: Int
    let versions: [String]
    enum CodingKeys: String, CodingKey {
        case title, description, author, downloads, versions
        case projectID = "project_id"
    }
}

extension CLI {
    static func runResourcePackCommand(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing resource pack action", suggestion: "Use `lingxi resourcepack search|list|install|import|enable|disable|delete|updates`.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "search": return try await resourcePackSearch(rest)
        case "list": return try resourcePackList(rest)
        case "install": return try await resourcePackInstall(rest)
        case "import": return try resourcePackImport(rest)
        case "enable": return try resourcePackSetEnabled(rest, enabled: true)
        case "disable": return try resourcePackSetEnabled(rest, enabled: false)
        case "delete", "remove": return try resourcePackDelete(rest)
        case "updates": return try await resourcePackUpdates(rest)
        default: throw LauncherError(.usageError, "Unknown resource pack action '\(action)'")
        }
    }

    private static func resourcePackManager(_ input: CommandLineInput) throws -> (ResourcePackManager, String) {
        let layout = try resolveLayout(input)
        return (ResourcePackManager(layout: layout), try input.requireValue("instance"))
    }

    private static func gameVersion(instanceID: String, layout: GameDataLayout) throws -> String {
        let instance = try InstanceRepository(layout: layout).load(id: instanceID)
        guard let versionID = instance.manifest.versionID else { return "" }
        let resolved = try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
        return resolved.inheritsFrom ?? resolved.id
    }

    private static func resourcePackSearch(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["query", "instance", "root", "data-root", "limit"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") { print("usage: lingxi resourcepack search --instance <id> --query <text> [--json]"); return 0 }
        let (manager, instanceID) = try resourcePackManager(input)
        let version = try gameVersion(instanceID: instanceID, layout: manager.layout)
        let result = try await manager.search(query: try input.requireValue("query"), gameVersion: version)
        if input.has("json") {
            CLIOutput.emitJSON(result.hits.map { JSONResourcePackHit(projectID: $0.projectID, title: $0.title, description: $0.description, author: $0.author, downloads: $0.downloads, versions: $0.versions) })
        } else {
            CLIOutput.header("Resource packs")
            for hit in result.hits {
                print("  \(hit.title)  [\(hit.projectID)]  \(hit.downloads) downloads")
            }
        }
        return 0
    }

    private static func resourcePackList(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") { print("usage: lingxi resourcepack list --instance <id> [--json]"); return 0 }
        let (manager, instanceID) = try resourcePackManager(input)
        let records = try manager.list(instanceID: instanceID)
        if input.has("json") {
            CLIOutput.emitJSON(records.map { JSONResourcePack(fileName: $0.fileName, title: $0.title, projectID: $0.projectID, versionID: $0.versionID, version: $0.versionNumber, source: $0.source, enabled: $0.enabled, bytes: $0.byteCount) })
        } else {
            CLIOutput.header("Installed resource packs")
            for record in records {
                print("  \(record.enabled ? "[x]" : "[ ]") \(record.title)  \(record.fileName)  \(record.source)")
            }
        }
        return 0
    }

    private static func resourcePackInstall(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "project", "version", "root", "data-root"], flagOptions: ["replace", "json"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") { print("usage: lingxi resourcepack install --instance <id> --project <id> --version <id> [--replace]"); return 0 }
        let (manager, instanceID) = try resourcePackManager(input)
        let record = try await manager.install(
            instanceID: instanceID,
            projectID: try input.requireValue("project"),
            versionID: try input.requireValue("version"),
            allowReplace: input.has("replace")
        )
        if input.has("json") {
            CLIOutput.emitJSON(JSONResourcePack(fileName: record.fileName, title: record.title, projectID: record.projectID, versionID: record.versionID, version: record.versionNumber, source: record.source, enabled: record.enabled, bytes: record.byteCount))
        } else {
            print("Installed \(record.title) → \(record.fileName)")
        }
        return 0
    }

    private static func resourcePackImport(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "file", "root", "data-root"], flagOptions: ["json"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") { print("usage: lingxi resourcepack import --instance <id> --file <zip>"); return 0 }
        let (manager, instanceID) = try resourcePackManager(input)
        let path = try input.requireValue("file")
        let record = try manager.importLocal(instanceID: instanceID, archiveURL: URL(fileURLWithPath: path))
        if input.has("json") {
            CLIOutput.emitJSON(JSONResourcePack(fileName: record.fileName, title: record.title, projectID: record.projectID, versionID: record.versionID, version: record.versionNumber, source: record.source, enabled: record.enabled, bytes: record.byteCount))
        } else {
            print("Imported \(record.title) → \(record.fileName)")
        }
        return 0
    }

    private static func resourcePackSetEnabled(_ arguments: [String], enabled: Bool) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "file", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") { print("usage: lingxi resourcepack enable|disable --instance <id> --file <name>"); return 0 }
        let (manager, instanceID) = try resourcePackManager(input)
        try manager.setEnabled(instanceID: instanceID, fileName: try input.requireValue("file"), enabled: enabled)
        print(enabled ? "Enabled" : "Disabled")
        return 0
    }

    private static func resourcePackDelete(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "file", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") { print("usage: lingxi resourcepack delete --instance <id> --file <name>"); return 0 }
        let (manager, instanceID) = try resourcePackManager(input)
        try manager.delete(instanceID: instanceID, fileName: try input.requireValue("file"))
        print("Deleted")
        return 0
    }

    private static func resourcePackUpdates(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"], flagOptions: ["install", "json"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") { print("usage: lingxi resourcepack updates --instance <id> [--install]"); return 0 }
        let (manager, instanceID) = try resourcePackManager(input)
        let updates = try await manager.setUpdates(instanceID: instanceID)
        if updates.isEmpty { print("No updates"); return 0 }
        for update in updates {
            print("\(update.current.title): \(update.current.versionNumber ?? "?") → \(update.version.versionNumber)")
            if input.has("install"), let file = update.version.primaryZip {
                _ = try await manager.install(instanceID: instanceID, projectID: update.version.projectID, versionID: update.version.id, allowReplace: true)
                print("  installed \(file.filename)")
            }
        }
        return 0
    }
}
