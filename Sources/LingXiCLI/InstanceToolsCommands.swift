import Foundation
import LauncherCore

/// CLI surface for instance copy, world backups and crash diagnostics. Every operation calls the
/// same LauncherCore service used by the SwiftUI app; no filesystem rules are duplicated here.
enum InstanceToolsCLI {
    private struct CopyJSON: Encodable {
        let sourceID: String
        let instanceID: String
        let displayName: String
        let gameDirectory: String
        let copiedPaths: [String]
        let includeSaves: Bool
    }

    private struct WorldJSON: Encodable {
        let name: String
        let byteCount: Int
        let modifiedAt: Date?
    }

    private struct BackupJSON: Encodable {
        let id: String
        let instanceID: String
        let worldName: String
        let fileCount: Int
        let totalBytes: Int
        let createdAt: Date
        let directory: String
    }

    private struct DiagnosisJSON: Encodable {
        let report: CrashDiagnosticReport
    }

    static func copy(_ arguments: [String]) throws -> Int32 {
        guard let sourceID = arguments.first else {
            throw LauncherError(.usageError, "Missing source instance id", suggestion: "Use `lingxi instance copy <source-id> --name <new-name> [--saves]`.")
        }
        let spec = ArgumentParser.Spec(valueOptions: ["name", "root", "data-root"], flagOptions: ["json", "help", "saves"])
        let input = try ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec)
        if input.has("help") {
            print("usage: lingxi instance copy <source-id> --name <new-name> [--saves] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try CLI.resolveLayout(input, requireGameRoot: false)
        let repository = InstanceRepository(layout: layout)
        _ = repository
        let service = InstanceCopyService(layout: layout)
        let report = try service.copy(
            instanceID: sourceID,
            displayName: input.requireValue("name"),
            options: InstanceCopyOptions(includeSaves: input.has("saves"))
        )
        if input.has("json") {
            CLIOutput.emitJSON(CopyJSON(
                sourceID: report.sourceID,
                instanceID: report.instance.id,
                displayName: report.instance.manifest.displayName,
                gameDirectory: report.instance.gameDirectory.path,
                copiedPaths: report.copiedPaths,
                includeSaves: report.includeSaves
            ))
        } else {
            print("Instance copied: \(report.instance.id)")
            CLIOutput.field("source", report.sourceID)
            CLIOutput.field("display name", report.instance.manifest.displayName)
            CLIOutput.field("game directory", report.instance.gameDirectory.path)
            CLIOutput.field("copied", report.copiedPaths.joined(separator: ", "))
            CLIOutput.field("saves", report.includeSaves ? "included" : "skipped")
        }
        return ExitStatus.success.rawValue
    }

    static func runWorld(_ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing world action", suggestion: "Use `lingxi world list --instance <id>`.")
        }
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "world", "backup", "root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec)
        if input.has("help") {
            print("usage: lingxi world list|backup|restore|delete --instance <id> [--world <name>] [--backup <id>]")
            return ExitStatus.success.rawValue
        }
        let layout = try CLI.resolveLayout(input, requireGameRoot: false)
        let manager = WorldBackupManager(layout: layout)
        let instanceID = try input.requireValue("instance")
        switch action {
        case "list":
            let worlds = try manager.listWorlds(instanceID: instanceID)
            let backups = try manager.listBackups(instanceID: instanceID)
            if input.has("json") {
                struct Payload: Encodable {
                    let worlds: [WorldJSON]
                    let backups: [BackupJSON]
                }
                CLIOutput.emitJSON(Payload(
                    worlds: worlds.map { WorldJSON(name: $0.name, byteCount: $0.byteCount, modifiedAt: $0.modifiedAt) },
                    backups: backups.map(backupJSON)
                ))
            } else {
                print("Worlds:")
                for world in worlds {
                    print("  \(world.name)  \(world.byteCount) bytes")
                }
                print("Backups:")
                for backup in backups {
                    print("  \(backup.id)  \(backup.worldName)  \(backup.fileCount) files  \(backup.totalBytes) bytes")
                }
            }
        case "backup":
            let summary = try manager.createBackup(instanceID: instanceID, worldName: input.requireValue("world"))
            print("Backup created: \(summary.id)")
            CLIOutput.field("world", summary.worldName)
            CLIOutput.field("files", "\(summary.fileCount)")
            CLIOutput.field("bytes", "\(summary.totalBytes)")
        case "restore":
            let world = try manager.restore(
                instanceID: instanceID,
                backupID: input.requireValue("backup"),
                worldName: input.value("world")
            )
            print("Restored world: \(world.lastPathComponent)")
            CLIOutput.field("instance", instanceID)
        case "delete":
            try manager.deleteBackup(instanceID: instanceID, backupID: input.requireValue("backup"))
            print("Backup deleted: \(try input.requireValue("backup"))")
        default:
            throw LauncherError(.usageError, "Unknown world action '\(action)'")
        }
        return ExitStatus.success.rawValue
    }

    static func runDiagnose(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root", "exit-code"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi diagnose --instance <id> [--exit-code <n>] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try CLI.resolveLayout(input, requireGameRoot: false)
        let service = CrashDiagnosticsService(layout: layout)
        let exitCode = input.value("exit-code").flatMap(Int32.init)
        let report = try service.collect(instanceID: input.requireValue("instance"), exitCode: exitCode)
        if input.has("json") {
            CLIOutput.emitJSON(DiagnosisJSON(report: report))
        } else {
            print("Diagnosis: \(report.summary)")
            CLIOutput.field("abnormal exit", report.abnormalExit ? "yes" : "no")
            for diagnostic in report.diagnostics {
                let root = diagnostic.isRootCause ? " [root cause]" : (diagnostic.isSecondary ? " [secondary]" : "")
                print("- \(diagnostic.category.displayName) (\(diagnostic.confidence.rawValue))\(root)")
                print("  \(diagnostic.explanation)")
                for recommendation in diagnostic.recommendations {
                    print("  -> \(recommendation)")
                }
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func backupJSON(_ summary: WorldBackupSummary) -> BackupJSON {
        BackupJSON(
            id: summary.id,
            instanceID: summary.instanceID,
            worldName: summary.worldName,
            fileCount: summary.fileCount,
            totalBytes: summary.totalBytes,
            createdAt: summary.createdAt,
            directory: summary.directory.path
        )
    }
}
