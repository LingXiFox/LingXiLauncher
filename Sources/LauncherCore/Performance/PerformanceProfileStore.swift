import Foundation

public struct PerformanceApplyResult: Codable, Sendable, Equatable {
    public let profile: AppliedPerformanceProfile
    public let backupPath: String
    public let auditPath: String

    public init(profile: AppliedPerformanceProfile, backupPath: String, auditPath: String) {
        self.profile = profile
        self.backupPath = backupPath
        self.auditPath = auditPath
    }
}

/// Persists tuner decisions outside the game directory. Applying a plan snapshots the exact old
/// heap/args first, then uses the repository's atomic instance.json write. If the profile write
/// fails, the old settings are restored; game files are never touched.
public struct PerformanceProfileStore: Sendable {
    private let layout: GameDataLayout
    private let repository: InstanceRepository
    private let runtime: InstanceRuntimeChecking
    private var fileManager: FileManager { .default }

    public init(
        layout: GameDataLayout,
        repository: InstanceRepository? = nil,
        runtime: InstanceRuntimeChecking? = nil
    ) {
        self.layout = layout
        self.repository = repository ?? InstanceRepository(layout: layout)
        self.runtime = runtime ?? InstanceRuntimeRegistry(layout: layout)
    }

    public var performanceRoot: URL {
        layout.dataRoot.appendingPathComponent("performance", isDirectory: true)
    }

    public var reportsDirectory: URL {
        performanceRoot.appendingPathComponent("reports", isDirectory: true)
    }

    public func profileURL(instanceID: String) throws -> URL {
        let component = try PathSafety.validatedPathComponent(instanceID)
        return performanceRoot.appendingPathComponent("profiles/\(component).json")
    }

    public func loadProfile(instanceID: String) throws -> AppliedPerformanceProfile? {
        let url = try profileURL(instanceID: instanceID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try Self.decoder.decode(AppliedPerformanceProfile.self, from: Data(contentsOf: url))
        } catch {
            throw LauncherError(.invalidMetadata, "Cannot read performance profile: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public func apply(
        instanceID: String,
        plan: PerformanceTuningPlan,
        baselineReportID: UUID? = nil,
        confirmed: Bool
    ) throws -> PerformanceApplyResult {
        guard confirmed else {
            throw LauncherError(.usageError, "Applying performance changes requires explicit confirmation")
        }
        guard !runtime.isRunning(instanceID: instanceID) else {
            throw LauncherError(.launchFailed, "Stop the game before applying performance settings")
        }
        var instance = try repository.load(id: instanceID)
        guard instance.id == plan.instanceID else {
            throw LauncherError(.usageError, "Performance plan belongs to a different instance")
        }
        guard (256...65_536).contains(plan.targetHeapMiB) else {
            throw LauncherError(.usageError, "Invalid performance heap")
        }
        let unsafe = plan.targetJVMArguments.filter {
            $0.hasPrefix("-Xmx") || $0.hasPrefix("-Xms") || $0.contains("\n") || $0.contains("\0")
        }
        guard unsafe.isEmpty else {
            throw LauncherError(.usageError, "Unsafe JVM arguments in performance plan")
        }
        let oldHeap = instance.manifest.memoryMiB
        let oldArguments = instance.manifest.jvmArguments

        let instanceComponent = try PathSafety.validatedPathComponent(instanceID)
        let backupDirectory = performanceRoot.appendingPathComponent("backups/\(instanceComponent)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = Self.timestamp()
        let backupURL = backupDirectory.appendingPathComponent("settings-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        let backup = PerformanceSettingsBackup(
            instanceID: instanceID,
            heapMiB: oldHeap,
            jvmArguments: oldArguments,
            createdAt: Date()
        )
        do {
            try Self.encoder.encode(backup).write(to: backupURL, options: .atomic)
            _ = try repository.setPerformance(
                id: instanceID,
                heapMiB: plan.targetHeapMiB,
                jvmArguments: plan.targetJVMArguments.isEmpty ? nil : plan.targetJVMArguments
            )
            instance = try repository.load(id: instanceID)
            let profile = AppliedPerformanceProfile(
                instanceID: instanceID,
                heapMiB: plan.targetHeapMiB,
                jvmArguments: plan.targetJVMArguments,
                sourceRecommendationID: plan.recommendations.first?.id,
                baselineReportID: baselineReportID
            )
            let url = try profileURL(instanceID: instanceID)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(profile).write(to: url, options: .atomic)
            let auditPath = try appendAudit(action: "apply", instanceID: instanceID, detail: "heap=\(plan.targetHeapMiB)")
            return PerformanceApplyResult(profile: profile, backupPath: backupURL.path, auditPath: auditPath)
        } catch {
            // Restore the exact previous settings. `setPerformance` is atomic; if even that
            // fails the original backup remains on disk for manual recovery.
            _ = try? repository.setPerformance(id: instanceID, heapMiB: oldHeap, jvmArguments: oldArguments)
            throw LauncherError(.ioFailure, "Performance settings were not applied: \(error.localizedDescription) (backup: \(backupURL.path))")
        }
    }

    public func restore(instanceID: String, confirmed: Bool) throws -> PerformanceApplyResult {
        guard confirmed else {
            throw LauncherError(.usageError, "Restoring performance settings requires confirmation")
        }
        guard !runtime.isRunning(instanceID: instanceID) else {
            throw LauncherError(.launchFailed, "Stop the game before restoring performance settings")
        }
        let component = try PathSafety.validatedPathComponent(instanceID)
        let directory = performanceRoot.appendingPathComponent("backups/\(component)", isDirectory: true)
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let latest = files.filter({ $0.pathExtension == "json" }).max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            throw LauncherError(.missingDependency, "No performance backup exists for this instance")
        }
        let backup = try Self.decoder.decode(PerformanceSettingsBackup.self, from: Data(contentsOf: latest))
        guard backup.instanceID == instanceID else {
            throw LauncherError(.invalidMetadata, "Performance backup belongs to another instance")
        }
        _ = try repository.setPerformance(
            id: instanceID,
            heapMiB: backup.heapMiB,
            jvmArguments: backup.jvmArguments
        )
        let profile = AppliedPerformanceProfile(
            instanceID: instanceID,
            heapMiB: backup.heapMiB,
            jvmArguments: backup.jvmArguments ?? [],
            sourceRecommendationID: "restored",
            appliedAt: Date(),
            baselineReportID: nil
        )
        let url = try profileURL(instanceID: instanceID)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(profile).write(to: url, options: .atomic)
        let auditPath = try appendAudit(action: "restore", instanceID: instanceID, detail: latest.lastPathComponent)
        return PerformanceApplyResult(profile: profile, backupPath: latest.path, auditPath: auditPath)
    }

    public func saveReport(_ report: BenchmarkReport) throws -> URL {
        try fileManager.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let url = reportsDirectory.appendingPathComponent("\(report.id.uuidString).json")
        try Self.encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    public func loadReports(instanceID: String) -> [BenchmarkReport] {
        guard let urls = try? fileManager.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let report = try? Self.decoder.decode(BenchmarkReport.self, from: data),
                  report.instanceID == instanceID else { return nil }
            return report
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func appendAudit(action: String, instanceID: String, detail: String) throws -> String {
        let directory = performanceRoot.appendingPathComponent("audit", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("performance.jsonl")
        let entry: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "action": action,
            "instance": instanceID,
            "detail": detail
        ]
        let data = try JSONEncoder().encode(entry) + Data("\n".utf8)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
        return url.path
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct PerformanceSettingsBackup: Codable, Sendable {
    let instanceID: String
    let heapMiB: Int?
    let jvmArguments: [String]?
    let createdAt: Date
}
