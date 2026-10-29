import Foundation
import LauncherCore

private struct JSONMrpackInspect: Encodable {
    let name: String
    let versionID: String
    let minecraftVersion: String
    let loader: String
    let fileCount: Int
    let overrideCount: Int
    let totalDownloadBytes: Int
    let skippedClientUnsupported: Int
    enum CodingKeys: String, CodingKey {
        case name, loader
        case versionID = "version_id"
        case minecraftVersion = "minecraft_version"
        case fileCount = "file_count"
        case overrideCount = "override_count"
        case totalDownloadBytes = "total_download_bytes"
        case skippedClientUnsupported = "skipped_client_unsupported"
    }
}

private struct JSONMrpackInstall: Encodable {
    let instanceID: String
    let displayName: String
    let minecraftVersion: String
    let loader: String
    let installedVersionID: String
    let installedFiles: Int
    let downloadedFiles: Int
    let downloadedBytes: Int
    let identifiedMods: Int
    let localMods: Int
    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case displayName = "display_name"
        case minecraftVersion = "minecraft_version"
        case loader
        case installedVersionID = "installed_version_id"
        case installedFiles = "installed_files"
        case downloadedFiles = "downloaded_files"
        case downloadedBytes = "downloaded_bytes"
        case identifiedMods = "identified_mods"
        case localMods = "local_mods"
    }
}

extension CLI {
    static func runMrpackCommand(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing mrpack action", suggestion: "Use `lingxi mrpack inspect|install`.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "inspect": return try await runMrpackInspect(rest)
        case "install": return try await runMrpackInstall(rest)
        default: throw LauncherError(.usageError, "Unknown mrpack action '\(action)'")
        }
    }

    private static func parseMrpack(_ input: CommandLineInput) throws -> MrpackPackage {
        let file = URL(fileURLWithPath: (try input.requireValue("file") as NSString).expandingTildeInPath)
        let extraction = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-mrpack-cli-\(UUID().uuidString)", isDirectory: true)
        return try MrpackParser.parse(archive: file, extractionRoot: extraction)
    }

    private static func loaderLabel(_ loader: InstallLoaderChoice) -> String {
        switch loader {
        case .vanilla: return "vanilla"
        case let .fabric(version): return version.map { "fabric-\($0)" } ?? "fabric"
        case let .neoforge(version): return version.map { "neoforge-\($0)" } ?? "neoforge"
        }
    }

    private static func runMrpackInspect(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["file"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi mrpack inspect --file <pack.mrpack> [--json]")
            return ExitStatus.success.rawValue
        }
        let package = try parseMrpack(input)
        defer { try? FileManager.default.removeItem(at: package.extractionRoot) }
        if input.has("json") {
            CLIOutput.emitJSON(JSONMrpackInspect(
                name: package.name,
                versionID: package.versionID,
                minecraftVersion: package.minecraftVersion,
                loader: loaderLabel(package.loader),
                fileCount: package.files.count,
                overrideCount: package.overrides.count,
                totalDownloadBytes: package.totalDownloadBytes,
                skippedClientUnsupported: package.skippedClientUnsupported
            ))
        } else {
            CLIOutput.header("Modrinth modpack: \(package.name)")
            CLIOutput.field("version", package.versionID)
            CLIOutput.field("minecraft", package.minecraftVersion)
            CLIOutput.field("loader", loaderLabel(package.loader))
            CLIOutput.field("files", "\(package.files.count) external + \(package.overrides.count) overrides")
            CLIOutput.field("download size", Downloader.format(bytes: package.totalDownloadBytes))
            if package.skippedClientUnsupported > 0 {
                CLIOutput.field("skipped", "\(package.skippedClientUnsupported) server-only file(s)")
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func runMrpackInstall(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(
            valueOptions: ["file", "name", "java", "root", "data-root", "source", "mirror-config", "concurrency", "optional"],
            flagOptions: ["json", "help"]
        )
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi mrpack install --file <pack.mrpack> [--name <display name>] [--java <path>] [--root <path>] [--data-root <path>] [--source auto|official|mirror|local-cache-only] [--optional <path[,path]>] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input)
        let sourceRaw = input.value("source") ?? DownloadSourcePolicy.auto.rawValue
        guard let source = DownloadSourcePolicy(rawValue: sourceRaw) else {
            throw LauncherError(.usageError, "Invalid --source value", suggestion: "Use auto, official, mirror or local-cache-only.")
        }
        let mirror = try input.value("mirror-config").map {
            try TrustedMirrorConfiguration.load(from: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
        }
        let package = try parseMrpack(input)
        defer { try? FileManager.default.removeItem(at: package.extractionRoot) }
        let installer = MrpackInstaller(layout: layout, transport: URLSessionTransport(), mirror: mirror)
        let javaPath: URL
        if let raw = input.value("java") {
            javaPath = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else if let requirement = try? await installer.requiredJava(for: package),
                  let selected = JavaManager(layout: layout, transport: URLSessionTransport())
                    .selectCompatible(requirement: requirement) {
            javaPath = selected.executable
        } else {
            javaPath = try services.javaInspector.discoverDefaultExecutable()
        }
        _ = try services.javaInspector.inspect(executable: javaPath)
        let report = try await installer.install(
            MrpackInstallRequest(
                package: package,
                displayName: input.value("name"),
                javaExecutable: javaPath,
                sourcePolicy: source,
                concurrency: Int(input.value("concurrency") ?? "4") ?? 4,
                selectedOptionalPaths: Set(
                    (input.value("optional") ?? "")
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                ),
                traceModrinthSources: true
            ),
            progress: { event in
                CLIOutput.fail("[mrpack] \(event.message) (\(event.completed)/\(event.total))")
            }
        )
        if input.has("json") {
            CLIOutput.emitJSON(JSONMrpackInstall(
                instanceID: report.instanceID,
                displayName: report.displayName,
                minecraftVersion: report.minecraftVersionID,
                loader: loaderLabel(report.loader),
                installedVersionID: report.installedVersionID,
                installedFiles: report.installedFiles,
                downloadedFiles: report.downloadedFiles,
                downloadedBytes: report.downloadedBytes,
                identifiedMods: report.identifiedMods,
                localMods: report.localMods
            ))
        } else {
            CLIOutput.header("Modpack installed")
            CLIOutput.field("instance", report.instanceID)
            CLIOutput.field("name", report.displayName)
            CLIOutput.field("minecraft", report.minecraftVersionID)
            CLIOutput.field("loader", loaderLabel(report.loader))
            CLIOutput.field("files", "\(report.installedFiles) committed")
            CLIOutput.field("sources", "\(report.identifiedMods) Modrinth · \(report.localMods) local")
            CLIOutput.field("game directory", report.gameDirectory.path)
        }
        return ExitStatus.success.rawValue
    }
}
