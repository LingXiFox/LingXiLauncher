import Foundation
import LauncherCore

enum WorldCommands {
    static func run(_ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing world action", suggestion: "Use `lingxi world list|backup|restore|delete`.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "list", "backups":
            return try list(rest, backups: action == "backups")
        case "backup":
            return try backup(rest)
        case "restore":
            return try restore(rest)
        case "delete":
            return try delete(rest)
        default:
            throw LauncherError(.usageError, "Unknown world action '\(action)'")
        }
    }

    private static func list(_ arguments: [String], backups: Bool) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        let layout = try CLI.resolveLayout(input)
        let instanceID = try input.requireValue("instance")
        let manager = WorldBackupManager(layout: layout)
        if backups {
            let values = try manager.listBackups(instanceID: instanceID)
            print("Backups (\(values.count))")
            print(String(repeating: "-", count: 44))
            for value in values {
                print("  \(value.id)  \(value.worldName)  \(value.fileCount) files  \(value.totalBytes) bytes")
            }
        } else {
            let values = try manager.listWorlds(instanceID: instanceID)
            print("Worlds (\(values.count))")
            print(String(repeating: "-", count: 44))
            for value in values { print("  \(value.name)  \(value.byteCount) bytes") }
        }
        return 0
    }

    private static func backup(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "world", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        let layout = try CLI.resolveLayout(input)
        let manager = WorldBackupManager(layout: layout)
        let result = try manager.createBackup(
            instanceID: try input.requireValue("instance"),
            worldName: try input.requireValue("world")
        )
        print("World backup created")
        print("  id        \(result.id)")
        print("  world     \(result.worldName)")
        print("  files     \(result.fileCount)")
        print("  bytes     \(result.totalBytes)")
        print("  directory \(result.directory.path)")
        return 0
    }

    private static func restore(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "backup", "world", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        let layout = try CLI.resolveLayout(input)
        let manager = WorldBackupManager(layout: layout)
        let url = try manager.restore(
            instanceID: try input.requireValue("instance"),
            backupID: try input.requireValue("backup"),
            worldName: input.value("world")
        )
        print("World restored: \(url.path)")
        return 0
    }

    private static func delete(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "backup", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        let layout = try CLI.resolveLayout(input)
        try WorldBackupManager(layout: layout).deleteBackup(
            instanceID: try input.requireValue("instance"),
            backupID: try input.requireValue("backup")
        )
        print("World backup deleted")
        return 0
    }
}
