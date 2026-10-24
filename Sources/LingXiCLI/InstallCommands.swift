import Foundation
import LauncherCore

// MARK: - M2 commands

extension CLI {
    static func runVersionList(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["type", "root", "data-root", "source", "mirror-config"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi version list [--type release|snapshot|all] [--source official|auto|mirror] [--root <path>] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input)
        let policy = try sourcePolicy(input)
        let mirror = try mirrorConfiguration(input)
        let type = try versionType(input.value("type"))
        let installer = VanillaInstaller(
            layout: layout,
            transport: URLSessionTransport(),
            mirror: mirror
        )
        let entries = try await installer.listVersions(type: type, policy: policy)

        if input.has("json") {
            CLIOutput.emitJSON(JSONVersionList(
                source: policy.rawValue,
                count: entries.count,
                versions: entries.map(JSONVersionEntry.init)
            ))
            return ExitStatus.success.rawValue
        }

        CLIOutput.header("Minecraft versions (\(type?.rawValue ?? "all"), source: \(policy.displayName))")
        print("\(entries.count) version(s) available; showing the newest \(min(entries.count, 15)):")
        for entry in entries.prefix(15) {
            print("  \(entry.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(entry.type.rawValue)  \(entry.releaseTime ?? "")")
        }
        if let latestRelease = entries.first(where: { $0.type == .release }) {
            print("Tip: install the newest release with `lingxi install vanilla --version \(latestRelease.id) --instance <id>`.")
        }
        return ExitStatus.success.rawValue
    }

    static func runInstall(_ arguments: [String]) async throws -> Int32 {
        guard let loader = arguments.first else {
            throw LauncherError(.usageError, "Missing install target", suggestion: "Use `lingxi install vanilla --version <id> --instance <id>`.")
        }
        guard loader == "vanilla" else {
            throw LauncherError(
                .notImplemented,
                "Only vanilla installation is implemented (M2); '\(loader)' arrives with M4",
                suggestion: "Use `lingxi install vanilla ...`."
            )
        }
        let spec = ArgumentParser.Spec(
            valueOptions: ["version", "instance", "name", "root", "data-root", "source", "mirror-config", "concurrency", "java"],
            flagOptions: ["json", "help"]
        )
        let input = try ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec)
        if input.has("help") {
            print("""
            usage: lingxi install vanilla --version <id> --instance <instance-id> [options]

              --version <id>        Minecraft version id from the official manifest
              --instance <id>       stable instance id to create or update
              --name "<label>"      display name (defaults to the instance id)
              --source <policy>     official | mirror | auto | local-cache-only (default: auto)
              --mirror-config <p>   trusted mirror JSON (required for --source mirror)
              --concurrency <n>     parallel downloads (default 4)
              --java <path>         runtime used only for the compatibility check
              --root <path>         Minecraft data root to install into
              --data-root <path>    LingXi data root (instances/natives/cache)
              --json                machine-readable final report
            """)
            return ExitStatus.success.rawValue
        }
        let versionID = try input.requireValue("version")
        let instanceID = try input.requireValue("instance")
        let layout = try resolveLayout(input)
        let policy = try sourcePolicy(input)
        let mirror = try mirrorConfiguration(input)
        let concurrency = Int(input.value("concurrency") ?? "4") ?? 4
        guard concurrency >= 1, concurrency <= 32 else {
            throw LauncherError(.usageError, "--concurrency must be between 1 and 32")
        }
        let javaURL = input.value("java").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let request = InstallRequest(
            versionID: versionID,
            instanceID: instanceID,
            displayName: input.value("name"),
            sourcePolicy: policy,
            concurrency: concurrency,
            javaExecutable: javaURL
        )

        if !input.has("json") {
            CLIOutput.header("Installing Minecraft \(versionID)")
            CLIOutput.field("instance", instanceID)
            CLIOutput.field("source", policy.displayName + (mirror.map { " via \($0.displayName)" } ?? ""))
            CLIOutput.field("game root", layout.gameRoot.path)
            CLIOutput.field("data root", layout.dataRoot.path)
            CLIOutput.field("concurrency", "\(concurrency)")
        }

        let printer = InstallProgressPrinter()
        let jsonMode = input.has("json")
        let installer = VanillaInstaller(
            layout: layout,
            transport: URLSessionTransport(),
            mirror: mirror
        )
        let report = try await installer.install(request, progress: { event in
            // JSON output must stay parseable: progress lines are human-mode only.
            if !jsonMode { printer.handle(event) }
        })

        if input.has("json") {
            CLIOutput.emitJSON(JSONInstallReport(report))
        } else {
            printer.finish()
            print("")
            CLIOutput.header("Install complete — Minecraft \(report.versionID)")
            CLIOutput.field("instance", "\(report.instanceID)  \(report.gameDirectory.path)")
            CLIOutput.field("downloaded", "\(report.downloadedFiles) file(s), \(Downloader.format(bytes: report.downloadedBytes))")
            CLIOutput.field("cache hits", "\(report.cacheHits) file(s)")
            CLIOutput.field("asset objects", "\(report.assetObjectCount)")
            CLIOutput.field("natives entries", "\(report.extractedNatives)")
            CLIOutput.field("source policy", report.sourcePolicy.displayName)
            if let required = report.javaRequirement.majorVersion {
                CLIOutput.field("java requirement", "Java \(required)+" + (report.javaRequirement.component.map { " (\($0))" } ?? ""))
            }
            CLIOutput.printDiagnostics(report.diagnostics)
            if report.missingAfterInstall.isEmpty {
                print("All required files are present. Next: `lingxi account local create --name <name>`, then `lingxi launch --instance \(report.instanceID) --identity local:<name> --dry-run`.")
            } else {
                CLIOutput.printMissing(report.missingAfterInstall)
                CLIOutput.fail("Install finished with \(report.missingAfterInstall.count) missing file(s).")
                return ExitStatus.preflightBlocked.rawValue
            }
        }
        return report.isComplete ? ExitStatus.success.rawValue : ExitStatus.preflightBlocked.rawValue
    }

    static func runVerify(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["instance", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi verify --instance <instance-id> [--root <path>] [--json]")
            return ExitStatus.success.rawValue
        }
        let instanceID = try input.requireValue("instance")
        let layout = try resolveLayout(input)
        let registry = InstanceRepository(layout: layout)
        let instance = try registry.load(id: instanceID)
        let verifier = InstallationVerifier(layout: layout)
        let report = try verifier.verify(instance: instance)

        if input.has("json") {
            CLIOutput.emitJSON(JSONVerifyReport(report))
        } else {
            CLIOutput.header("Verify instance \(instanceID)")
            CLIOutput.field("version", report.versionID)
            CLIOutput.field("checked files", "\(report.checkedFiles)")
            CLIOutput.field("checked size", Downloader.format(bytes: report.checkedBytes))
            if report.isClean {
                print("All files match the published SHA-1/size metadata.")
            } else {
                print("Problems: \(report.missingCount) missing, \(report.mismatchCount) corrupted, \(report.issues.count) total")
                for issue in report.issues.prefix(20) {
                    print("  - \(issue.description)")
                }
                if report.issues.count > 20 {
                    print("  … and \(report.issues.count - 20) more")
                }
                CLIOutput.fail("Verification failed: \(report.issues.count) issue(s). Re-run install to repair.")
                return ExitStatus.preflightBlocked.rawValue
            }
        }
        return report.isClean ? ExitStatus.success.rawValue : ExitStatus.preflightBlocked.rawValue
    }

    // MARK: - Option helpers

    static func sourcePolicy(_ input: CommandLineInput, default defaultValue: DownloadSourcePolicy = .official) throws -> DownloadSourcePolicy {
        guard let raw = input.value("source") else { return defaultValue }
        guard let policy = DownloadSourcePolicy(rawValue: raw) else {
            throw LauncherError(
                .usageError,
                "Unknown --source '\(raw)'",
                suggestion: "Use official, mirror, auto or local-cache-only."
            )
        }
        return policy
    }

    static func mirrorConfiguration(_ input: CommandLineInput) throws -> TrustedMirrorConfiguration? {
        let path = input.value("mirror-config")
            ?? ProcessInfo.processInfo.environment["LINGXI_MIRROR_CONFIG"]
        guard let path, !path.isEmpty else { return nil }
        return try TrustedMirrorConfiguration.load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func versionType(_ raw: String?) throws -> VersionManifest.Entry.Kind? {
        guard let raw else { return .release }
        switch raw {
        case "release": return .release
        case "snapshot": return .snapshot
        case "all": return nil
        case "old_beta": return .oldBeta
        case "old_alpha": return .oldAlpha
        default:
            throw LauncherError(.usageError, "Unknown --type '\(raw)'", suggestion: "Use release, snapshot or all.")
        }
    }
}

// MARK: - Progress printer

/// Throttled human progress output. Never leaks credentials: only file paths and byte counts.
final class InstallProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var totalToDownload = 0
    private var completed = 0
    private var bytes = 0
    private var failures = 0
    private var lastPrint = Date.distantPast

    func handle(_ event: InstallProgressEvent) {
        switch event {
        case let .phase(phase, message):
            print("[\(phase.rawValue)] \(message)")
        case let .plan(totalFiles, totalBytes, cacheHits):
            lock.lock()
            totalToDownload = max(0, totalFiles - cacheHits)
            lock.unlock()
            print("Plan: \(totalFiles) file(s), \(totalToDownload) to download (\(Downloader.format(bytes: totalBytes))), \(cacheHits) cached")
        case .fileStarted:
            break
        case let .fileFinished(path, size, source):
            lock.lock()
            completed += 1
            bytes += size
            let now = Date()
            let shouldPrint = now.timeIntervalSince(lastPrint) > 0.5 || size > 5 * 1024 * 1024
            if shouldPrint { lastPrint = now }
            let snapshot = (completed, totalToDownload, bytes)
            lock.unlock()
            if shouldPrint {
                let name = (path as NSString).lastPathComponent
                print("  [\(snapshot.0)/\(snapshot.1)] \(name) — \(Downloader.format(bytes: size)) (\(source))")
            }
        case let .fileFailed(path, message):
            lock.lock()
            failures += 1
            lock.unlock()
            CLIOutput.fail("  failed: \(path): \(message)")
        }
    }

    func finish() {
        lock.lock()
        let snapshot = (completed, bytes, failures)
        lock.unlock()
        print("Downloaded \(snapshot.0) file(s), \(Downloader.format(bytes: snapshot.1)), \(snapshot.2) failure(s).")
    }
}
