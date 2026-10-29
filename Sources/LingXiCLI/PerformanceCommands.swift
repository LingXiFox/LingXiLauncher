import Foundation
import LauncherCore

extension CLI {
    static func runPerformanceCommand(_ arguments: [String]) async throws -> Int32 {
        guard let subcommand = arguments.first else {
            print("usage: lingxi performance <status|benchmark|tune|apply|reports> [options]")
            return ExitStatus.usage.rawValue
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "status":
            return try performanceStatus(rest)
        case "benchmark", "bench":
            return try await performanceBenchmark(rest)
        case "tune", "recommend":
            return try performanceTune(rest)
        case "apply":
            return try performanceApply(rest)
        case "reports", "report":
            return try performanceReports(rest)
        default:
            throw LauncherError(.usageError, "Unknown performance command '\(subcommand)'")
        }
    }

    private static func performanceStatus(_ arguments: [String]) throws -> Int32 {
        let input = try ArgumentParser.parse(arguments, spec: ArgumentParser.Spec(valueOptions: ["root", "data-root", "instance"], flagOptions: ["json", "help"]))
        if input.has("help") { print("usage: lingxi performance status [--instance <id>] [--json]"); return 0 }
        let layout = try resolveLayout(input)
        let hardware = SystemProfiler.hardware()
        let instance = try input.value("instance").map { try InstanceRepository(layout: layout).load(id: $0) }
        let compatibility = instance.flatMap { try? ModCompatibilityResolver.resolve(instance: $0, layout: layout) }
        let status = PerformanceStatusOutput(
            cpu: hardware.cpuModel,
            architecture: hardware.architecture,
            physicalCores: hardware.physicalCores,
            memoryBytes: hardware.memoryBytes,
            operatingSystem: hardware.operatingSystem,
            gpu: hardware.gpuModel,
            instance: instance?.id,
            loader: compatibility?.loader.displayName,
            minecraftVersion: compatibility?.gameVersion,
            heapMiB: instance?.manifest.memoryMiB,
            jvmArguments: instance?.manifest.jvmArguments
        )
        if input.has("json") { CLIOutput.emitJSON(status) }
        else {
            print("CPU: \(status.cpu) (\(status.architecture), \(status.physicalCores) cores)")
            print("Memory: \(ByteCountFormatter.string(fromByteCount: Int64(status.memoryBytes), countStyle: .memory))")
            print("OS: \(status.operatingSystem)")
            if let gpu = status.gpu { print("GPU: \(gpu)") }
            if let instance = status.instance {
                print("Instance: \(instance) · \(status.loader ?? "Unknown") · \(status.minecraftVersion ?? "unknown")")
                print("Heap: \(status.heapMiB.map { "\($0) MiB" } ?? "automatic")")
                print("JVM: \(status.jvmArguments?.joined(separator: " ") ?? "none")")
            }
        }
        return 0
    }

    private static func performanceBenchmark(_ arguments: [String]) async throws -> Int32 {
        let input = try ArgumentParser.parse(arguments, spec: ArgumentParser.Spec(
            valueOptions: ["root", "data-root", "instance", "identity", "java", "warmup", "runs", "timeout", "world"],
            flagOptions: ["json", "help"]
        ))
        if input.has("help") {
            print("usage: lingxi performance benchmark --instance <id> --identity local:<name>|microsoft:<id> [--warmup 1] [--runs 3] [--timeout 180] [--world <name>] [--json]")
            return 0
        }
        let layout = try resolveLayout(input)
        let instanceID = try input.requireValue("instance")
        let instance = try InstanceRepository(layout: layout).load(id: instanceID)
        let identity = try await resolveIdentity(try input.requireValue("identity"), layout: layout)
        let javaURL: URL
        if let path = input.value("java") {
            javaURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            javaURL = try CLIServices().javaInspector.discoverDefaultExecutable()
        }
        let warmup = min(5, max(0, Int(input.value("warmup") ?? "1") ?? 1))
        let runs = min(10, max(1, Int(input.value("runs") ?? "3") ?? 3))
        let timeout = min(900, max(30, Double(input.value("timeout") ?? "180") ?? 180))
        let options = BenchmarkOptions(
            warmupRuns: warmup,
            measuredRuns: runs,
            timeoutSeconds: timeout,
            quickPlayWorld: input.value("world")
        )
        let runner = BenchmarkRunner(layout: layout)
        let report = try await runner.run(
            instance: instance,
            javaExecutable: javaURL,
            identity: identity,
            options: options
        )
        _ = try PerformanceProfileStore(layout: layout).saveReport(report)
        if input.has("json") {
            CLIOutput.emitJSON(report)
        } else {
            print("Benchmark complete: \(report.runs.count) measured runs")
            print("Startup avg: \(format(report.aggregate.startupAverage))")
            print("World avg: \(format(report.aggregate.worldLoadAverage))")
            print("CPU avg: \(format(report.aggregate.cpuAverage))")
            print("Peak RSS: \(report.aggregate.residentPeakBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "n/a")")
            print("FPS: unavailable (no external frame counter; not fabricated)")
        }
        return 0
    }

    private static func performanceTune(_ arguments: [String]) throws -> Int32 {
        let input = try ArgumentParser.parse(arguments, spec: ArgumentParser.Spec(valueOptions: ["root", "data-root", "instance"], flagOptions: ["json", "help"]))
        if input.has("help") { print("usage: lingxi performance tune --instance <id> [--json]"); return 0 }
        let layout = try resolveLayout(input)
        let instance = try InstanceRepository(layout: layout).load(id: try input.requireValue("instance"))
        let compatibility = try? ModCompatibilityResolver.resolve(instance: instance, layout: layout)
        let mods = (try? ModRepository(layout: layout).list(instance: instance).count) ?? 0
        let reports = PerformanceProfileStore(layout: layout).loadReports(instanceID: instance.id)
        let plan = PerformanceTuningEngine.makePlan(
            instance: instance,
            loader: compatibility?.loader.displayName ?? "Unknown",
            modCount: mods,
            baseline: reports.first
        )
        if input.has("json") { CLIOutput.emitJSON(plan) }
        else {
            print("Target heap: \(plan.targetHeapMiB) MiB")
            for item in plan.recommendations {
                print("[\(item.risk.displayName)] \(item.title): \(item.summary)")
            }
            print("Apply with: lingxi performance apply --instance \(instance.id) --yes")
        }
        return 0
    }

    private static func performanceApply(_ arguments: [String]) throws -> Int32 {
        let input = try ArgumentParser.parse(arguments, spec: ArgumentParser.Spec(valueOptions: ["root", "data-root", "instance"], flagOptions: ["yes", "json", "help"]))
        if input.has("help") { print("usage: lingxi performance apply --instance <id> --yes [--json]"); return 0 }
        guard input.has("yes") else {
            throw LauncherError(.usageError, "Applying performance changes requires --yes", suggestion: "Review with `lingxi performance tune --instance <id>` first.")
        }
        let layout = try resolveLayout(input)
        let instance = try InstanceRepository(layout: layout).load(id: try input.requireValue("instance"))
        let compatibility = try? ModCompatibilityResolver.resolve(instance: instance, layout: layout)
        let mods = (try? ModRepository(layout: layout).list(instance: instance).count) ?? 0
        let reports = PerformanceProfileStore(layout: layout).loadReports(instanceID: instance.id)
        let plan = PerformanceTuningEngine.makePlan(
            instance: instance,
            loader: compatibility?.loader.displayName ?? "Unknown",
            modCount: mods,
            baseline: reports.first
        )
        let result = try PerformanceProfileStore(layout: layout).apply(
            instanceID: instance.id,
            plan: plan,
            baselineReportID: reports.first?.id,
            confirmed: true
        )
        if input.has("json") { CLIOutput.emitJSON(result) }
        else { print("Applied heap \(result.profile.heapMiB.map(String.init) ?? "automatic") MiB; backup: \(result.backupPath)") }
        return 0
    }

    private static func performanceReports(_ arguments: [String]) throws -> Int32 {
        let input = try ArgumentParser.parse(arguments, spec: ArgumentParser.Spec(valueOptions: ["root", "data-root", "instance"], flagOptions: ["json", "help"]))
        if input.has("help") { print("usage: lingxi performance reports --instance <id> [--json]"); return 0 }
        let layout = try resolveLayout(input)
        let instanceID = try input.requireValue("instance")
        let reports = PerformanceProfileStore(layout: layout).loadReports(instanceID: instanceID)
        if input.has("json") { CLIOutput.emitJSON(reports) }
        else {
            for report in reports {
                print("\(report.id.uuidString)  \(report.createdAt.formatted(.iso8601))  startup=\(format(report.aggregate.startupAverage))  world=\(format(report.aggregate.worldLoadAverage))")
            }
        }
        return 0
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2fs", value)
    }
}

private struct PerformanceStatusOutput: Codable {
    let cpu: String
    let architecture: String
    let physicalCores: Int
    let memoryBytes: UInt64
    let operatingSystem: String
    let gpu: String?
    let instance: String?
    let loader: String?
    let minecraftVersion: String?
    let heapMiB: Int?
    let jvmArguments: [String]?
}
