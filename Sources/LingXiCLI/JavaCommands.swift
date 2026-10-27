import Foundation
import LauncherCore

extension CLI {
    static func runJavaCommand(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing Java action", suggestion: "Use `lingxi java list` or `lingxi java install --major 17 --yes`.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "list": return try runJavaList(rest)
        case "install": return try await runJavaInstall(rest)
        default: throw LauncherError(.usageError, "Unknown Java action '\(action)'")
        }
    }

    private static func runJavaList(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["data-root", "root"], flagOptions: ["help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi java list")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input, requireGameRoot: false)
        let manager = JavaManager(layout: layout, transport: URLSessionTransport())
        let runtimes = manager.detectRuntimes()
        CLIOutput.header("Java runtimes")
        if runtimes.isEmpty { print("No usable Java runtime found.") }
        for runtime in runtimes {
            let managed = manager.managedRuntimes().first { $0.runtime.executable == runtime.executable }
            print("  - \(runtime.displayDescription)")
            print("    path: \(runtime.executable.path)")
            print("    arch: \(runtime.architecture.rawValue)  source: \(managed?.source ?? "system/local")")
            if let managed {
                print("    license: \(managed.license)  url: \(managed.sourceURL.absoluteString)")
            }
        }
        return ExitStatus.success.rawValue
    }

    private static func runJavaInstall(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(
            valueOptions: ["major", "data-root", "root"],
            flagOptions: ["yes", "help"]
        )
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("""
            usage: lingxi java install --major <version> --yes [--data-root <path>]

            Downloads Eclipse Temurin for macOS arm64 into <dataRoot>/java, verifies its
            published SHA-256 and leaves system Java untouched. --yes is required because this
            is a multi-hundred-megabyte download.
            """)
            return ExitStatus.success.rawValue
        }
        let major = Int(try input.requireValue("major")) ?? 0
        guard major >= 8 else { throw LauncherError(.usageError, "--major must be at least 8") }
        guard input.has("yes") else {
            throw LauncherError(.usageError, "Refusing to download a JDK without --yes", suggestion: "Review the source and run again with --yes.")
        }
        let layout = try resolveLayout(input, requireGameRoot: false)
        let manager = JavaManager(layout: layout, transport: URLSessionTransport())
        print("Source: \(JavaManager.managedSourceName) (\(JavaManager.adoptiumAPI.absoluteString))/\(major)/hotspot")
        print("License: \(JavaManager.managedLicense)")
        let managed = try await manager.installManagedJava(majorVersion: major) { event in
            switch event {
            case let .metadata(message): CLIOutput.fail("[java] \(message)")
            case let .downloading(total): CLIOutput.fail("[java] downloading Temurin \(major)\(total.map { " (\(Downloader.format(bytes: $0)))" } ?? "")…")
            case let .verifying(checksum): CLIOutput.fail("[java] verifying SHA-256 \(checksum.prefix(16))…")
            case let .extracting(name): CLIOutput.fail("[java] extracting \(name)…")
            case let .ready(url): CLIOutput.fail("[java] ready: \(url.path)")
            }
        }
        CLIOutput.header("Managed Java installed")
        CLIOutput.field("runtime", managed.runtime.displayDescription)
        CLIOutput.field("path", managed.runtime.executable.path)
        CLIOutput.field("source", managed.source)
        CLIOutput.field("license", managed.license)
        CLIOutput.field("storage", managed.storage.path)
        return ExitStatus.success.rawValue
    }
}
