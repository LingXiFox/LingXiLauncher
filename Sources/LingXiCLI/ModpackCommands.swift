import Foundation
import LauncherCore

private struct JSONPackUpdatePlan: Encodable {
    let currentVersionID: String
    let targetVersionID: String
    let targetVersionNumber: String
    let minecraftVersion: String
    let loader: String
    let requiresMinecraftChange: Bool
    let requiresLoaderChange: Bool
    let files: Int
    let downloadBytes: Int
    let signature: String
    let changes: [JSONPackUpdateChange]
    enum CodingKeys: String, CodingKey {
        case loader, files, changes
        case currentVersionID = "current_version_id"
        case targetVersionID = "target_version_id"
        case targetVersionNumber = "target_version_number"
        case minecraftVersion = "minecraft_version"
        case requiresMinecraftChange = "requires_minecraft_change"
        case requiresLoaderChange = "requires_loader_change"
        case downloadBytes = "download_bytes"
        case signature
    }
}

private struct JSONPackUpdateChange: Encodable {
    let kind: String
    let path: String
    let userModified: Bool
    let reason: String
    enum CodingKeys: String, CodingKey {
        case kind, path, reason
        case userModified = "user_modified"
    }
}

private struct JSONPackUpdateReport: Encodable {
    let applied: [String]
    let preserved: [String]
    let skipped: [String]
    let removed: [String]
    let transactionID: String
    enum CodingKeys: String, CodingKey {
        case applied, preserved, skipped, removed
        case transactionID = "transaction_id"
    }
}

extension CLI {
    static func runModpackCommand(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing modpack action", suggestion: "Use `lingxi modpack update check|preview|apply|recover`.")
        }
        switch action {
        case "update": return try await runModpackUpdate(Array(arguments.dropFirst()))
        case "info": return try await runModpackInfo(Array(arguments.dropFirst()))
        default: throw LauncherError(.usageError, "Unknown modpack action '\(action)'")
        }
    }

    private static func updateManager(_ input: CommandLineInput) throws -> (GameDataLayout, String, ModpackUpdateManager) {
        let layout = try resolveLayout(input)
        guard let instanceID = input.value("instance"), !instanceID.isEmpty else {
            throw LauncherError(.usageError, "Missing --instance")
        }
        return (layout, instanceID, ModpackUpdateManager(layout: layout))
    }

    private static func runModpackInfo(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi modpack info --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (_, instanceID, manager) = try updateManager(input)
        let record = try manager.record(instanceID: instanceID)
        if input.has("json") {
            CLIOutput.emitJSON(record)
        } else {
            CLIOutput.header("Modpack \(instanceID)")
            CLIOutput.field("pack version", record.packVersionID ?? record.versionID)
            CLIOutput.field("minecraft", record.minecraftVersion)
            CLIOutput.field("loader", record.loaderKind + (record.loaderVersion.map { " \($0)" } ?? ""))
            CLIOutput.field("modrinth project", record.modrinthProjectID ?? record.projectID ?? "untracked")
            CLIOutput.field("modrinth version", record.modrinthVersionID ?? "untracked")
            CLIOutput.field("files", "\(record.files.count)")
        }
        return ExitStatus.success.rawValue
    }

    private static func runModpackUpdate(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing update action", suggestion: "Use check, preview, apply or recover.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "check": return try await modpackUpdateCheck(rest)
        case "preview": return try await modpackUpdatePreview(rest)
        case "apply": return try await modpackUpdateApply(rest)
        case "recover": return try await modpackUpdateRecover(rest)
        default: throw LauncherError(.usageError, "Unknown modpack update action '\(action)'")
        }
    }

    private static func targetVersion(_ input: CommandLineInput, manager: ModpackUpdateManager, instanceID: String) async throws -> ModrinthVersion {
        if let id = input.value("target") { return try await ModrinthClient().version(id: id) }
        guard let latest = try await manager.latestUpdate(instanceID: instanceID) else {
            throw LauncherError(.usageError, "No compatible pack update is available")
        }
        return latest
    }

    private static func modpackUpdateCheck(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi modpack update check --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (_, instanceID, manager) = try updateManager(input)
        guard let latest = try await manager.latestUpdate(instanceID: instanceID) else {
            if input.has("json") { print("{\"update\":null}") } else { print("Already up to date.") }
            return ExitStatus.success.rawValue
        }
        if input.has("json") {
            CLIOutput.emitJSON(["update": latest.id, "version_number": latest.versionNumber, "type": latest.versionType.rawValue])
        } else {
            CLIOutput.header("Pack update available")
            CLIOutput.field("version", latest.versionNumber)
            CLIOutput.field("id", latest.id)
            CLIOutput.field("channel", latest.versionType.rawValue)
        }
        return ExitStatus.success.rawValue
    }

    private static func modpackUpdatePreview(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "target", "root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi modpack update preview --instance <id> [--target <version-id>] [--json]")
            return ExitStatus.success.rawValue
        }
        let (_, instanceID, manager) = try updateManager(input)
        let target = try await targetVersion(input, manager: manager, instanceID: instanceID)
        let plan = try await manager.preview(instanceID: instanceID, targetVersionID: target.id)
        if input.has("json") {
            CLIOutput.emitJSON(JSONPackUpdatePlan(
                currentVersionID: plan.currentVersionID,
                targetVersionID: plan.targetVersionID,
                targetVersionNumber: plan.targetVersionNumber,
                minecraftVersion: plan.targetMinecraftVersion,
                loader: plan.targetLoaderKind,
                requiresMinecraftChange: plan.requiresMinecraftChange,
                requiresLoaderChange: plan.requiresLoaderChange,
                files: plan.changes.count,
                downloadBytes: plan.totalDownloadBytes,
                signature: plan.signature,
                changes: plan.changes.map {
                    JSONPackUpdateChange(kind: $0.kind.rawValue, path: $0.path, userModified: $0.userModified, reason: $0.reason)
                }
            ))
        } else {
            CLIOutput.header("Pack update \(plan.currentVersionID) → \(plan.targetVersionNumber)")
            CLIOutput.field("minecraft", plan.targetMinecraftVersion)
            CLIOutput.field("loader", plan.targetLoaderKind + (plan.targetLoaderVersion.map { " \($0)" } ?? ""))
            CLIOutput.field("changes", "\(plan.changes.count)")
            CLIOutput.field("download", Downloader.format(bytes: plan.totalDownloadBytes))
            CLIOutput.field("signature", plan.signature)
            for change in plan.changes where change.kind == .userModified || change.kind == .conflict {
                CLIOutput.field(change.kind.rawValue, change.path)
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func modpackUpdateApply(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(
            valueOptions: ["instance", "target", "preserve", "signature", "root", "data-root"],
            flagOptions: ["json", "yes", "help"]
        )
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi modpack update apply --instance <id> [--target <version-id>] [--preserve path[,path]] --yes [--json]")
            return ExitStatus.success.rawValue
        }
        guard input.has("yes") else {
            throw LauncherError(.usageError, "Pack updates modify instance files; pass --yes after reviewing preview")
        }
        let (_, instanceID, manager) = try updateManager(input)
        let target = try await targetVersion(input, manager: manager, instanceID: instanceID)
        var actions: [String: ModpackUpdateAction] = [:]
        for path in input.value("preserve")?.split(separator: ",") ?? [] {
            actions[String(path)] = .preserve
        }
        let report = try await manager.apply(
            instanceID: instanceID,
            targetVersionID: target.id,
            actions: actions,
            expectedPlanSignature: input.value("signature")
        )
        if input.has("json") {
            CLIOutput.emitJSON(JSONPackUpdateReport(
                applied: report.applied, preserved: report.preserved,
                skipped: report.skipped, removed: report.removed,
                transactionID: report.transactionID
            ))
        } else {
            CLIOutput.header("Pack update applied")
            CLIOutput.field("applied", "\(report.applied.count)")
            CLIOutput.field("preserved", "\(report.preserved.count)")
            CLIOutput.field("removed", "\(report.removed.count)")
        }
        return ExitStatus.success.rawValue
    }

    private static func modpackUpdateRecover(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi modpack update recover --instance <id> [--json]")
            return ExitStatus.success.rawValue
        }
        let (_, instanceID, manager) = try updateManager(input)
        let recovered = try manager.recover(instanceID: instanceID)
        if input.has("json") {
            CLIOutput.emitJSON(["recovered": recovered])
        } else {
            print(recovered ? "Recovered interrupted update." : "No interrupted update found.")
        }
        return ExitStatus.success.rawValue
    }
}
