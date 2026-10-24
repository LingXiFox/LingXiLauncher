import Foundation

/// Downloads a set of files to disk with bounded concurrency, SHA-1/size verification and
/// atomic placement.
///
/// Failure policy:
/// - Every file is attempted independently; one failure does not abort the rest (the installer
///   reports all failures together so the user can retry once).
/// - Retryable transport errors (network, 408/429/5xx) are retried per source with a capped
///   attempt count. 403/404 are terminal for that source.
/// - A hash/size mismatch never leaves a usable-looking file behind: the `.part` file is removed
///   and the next configured source is tried (`auto` mode).
/// - `local-cache-only` produces no candidates at all: missing files fail with an explanation
///   instead of silently contacting the network.
public struct Downloader: Sendable {
    private let transport: any DownloadTransport
    private let sourceResolver: SourceResolver
    private let configuration: DownloadConfiguration

    public init(
        transport: any DownloadTransport,
        sourceResolver: SourceResolver,
        configuration: DownloadConfiguration = DownloadConfiguration()
    ) {
        self.transport = transport
        self.sourceResolver = sourceResolver
        self.configuration = configuration
    }

    public func download(
        _ tasks: [DownloadTask],
        progress: @escaping @Sendable (InstallProgressEvent) -> Void
    ) async throws -> DownloadSummary {
        let uniqueTasks = Self.deduplicated(tasks)
        var cacheHits = 0
        var pending: [DownloadTask] = []
        for task in uniqueTasks {
            // Hash each cached candidate exactly once; large asset sets make double checks costly.
            if isCached(task) {
                cacheHits += 1
            } else {
                pending.append(task)
            }
        }
        // Duplicate destinations were removed above; sort by size descending so large files
        // start first and the tail of the install is not one giant straggler.
        pending.sort { ($0.size ?? 0) > ($1.size ?? 0) }

        let totalBytes = pending.reduce(0) { $0 + max(0, $1.size ?? 0) }
        progress(.plan(totalFiles: uniqueTasks.count, totalBytes: totalBytes, cacheHits: cacheHits))

        guard sourceResolver.allowsNetwork else {
            let failures = pending.map {
                DownloadFailure(
                    task: $0,
                    code: .missingDependency,
                    message: "local-cache-only: \($0.destination.path) is not present in the local cache"
                )
            }
            return DownloadSummary(downloaded: [], cacheHits: cacheHits, failures: failures)
        }

        try checkDiskSpace(for: pending)

        var downloaded: [DownloadedFile] = []
        var failures: [DownloadFailure] = []

        await withTaskGroup(of: DownloadResult.self) { group in
            var nextIndex = 0
            let initial = min(configuration.concurrency, pending.count)
            for _ in 0..<initial {
                let task = pending[nextIndex]
                nextIndex += 1
                group.addTask {
                    await self.perform(task: task, progress: progress)
                }
            }
            while let result = await group.next() {
                switch result {
                case let .success(file):
                    downloaded.append(file)
                case let .failure(failure):
                    failures.append(failure)
                }
                if nextIndex < pending.count {
                    let task = pending[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await self.perform(task: task, progress: progress)
                    }
                }
            }
        }

        // Stable, deterministic output ordering independent of completion order.
        downloaded.sort { $0.path.path < $1.path.path }
        failures.sort { $0.task.destination.path < $1.task.destination.path }
        return DownloadSummary(downloaded: downloaded, cacheHits: cacheHits, failures: failures)
    }

    // MARK: - Cache inspection

    private func isCached(_ task: DownloadTask) -> Bool {
        Self.fileMatches(task)
    }

    /// Existence + size + SHA-1 check. Used for cache hits and post-download verification.
    static func fileMatches(_ task: DownloadTask) -> Bool {
        let path = task.destination.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return false
        }
        if size == 0 { return false }
        if let expected = task.size, size != expected { return false }
        if let expected = task.sha1 {
            guard let actual = try? SHA1.hexDigest(ofFileAt: task.destination) else { return false }
            return actual == expected.lowercased()
        }
        return true
    }

    // MARK: - One file

    private enum DownloadResult: Sendable {
        case success(DownloadedFile)
        case failure(DownloadFailure)
    }

    private func perform(
        task: DownloadTask,
        progress: @Sendable @escaping (InstallProgressEvent) -> Void
    ) async -> DownloadResult {
        progress(.fileStarted(path: task.destination.path, size: task.size ?? 0))

        guard let officialURL = task.officialURL else {
            let failure = DownloadFailure(
                task: task,
                code: .missingDependency,
                message: "The version metadata provides no download URL for \(task.destination.lastPathComponent)"
            )
            progress(.fileFailed(path: task.destination.path, message: failure.message))
            return .failure(failure)
        }

        let candidates: [DownloadCandidate]
        do {
            candidates = try sourceResolver.candidates(for: officialURL)
        } catch let error as LauncherError {
            progress(.fileFailed(path: task.destination.path, message: error.message))
            return .failure(DownloadFailure(task: task, code: error.code, message: error.message))
        } catch {
            progress(.fileFailed(path: task.destination.path, message: error.localizedDescription))
            return .failure(DownloadFailure(task: task, code: .downloadFailed, message: error.localizedDescription))
        }

        if candidates.isEmpty {
            let message = "local-cache-only: \(task.destination.path) is not present in the local cache"
            progress(.fileFailed(path: task.destination.path, message: message))
            return .failure(DownloadFailure(task: task, code: .missingDependency, message: message))
        }

        var lastFailure = DownloadFailure(task: task, code: .downloadFailed, message: "No download source was attempted")

        for candidate in candidates {
            var attempt = 0
            while attempt < configuration.maxRetries {
                attempt += 1
                let partURL = Self.makePartURL(for: task.destination)
                do {
                    try await transport.download(from: candidate.url, to: partURL)
                    try Self.verify(partURL, task: task, source: candidate.sourceLabel)
                    let bytes = try Self.fileSize(partURL)
                    try Self.place(partURL, at: task.destination)
                    progress(.fileFinished(path: task.destination.path, bytes: bytes, source: candidate.sourceLabel))
                    return .success(DownloadedFile(path: task.destination, bytes: bytes, source: candidate.sourceLabel))
                } catch let error as TransportError {
                    try? FileManager.default.removeItem(at: partURL)
                    lastFailure = DownloadFailure(task: task, code: error.launcherCode, message: error.description)
                    if error.isRetryable, attempt < configuration.maxRetries {
                        try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds(attempt: attempt, base: configuration.retryDelay))
                        continue
                    }
                    break // try the next source (mirror), if any
                } catch let error as LauncherError {
                    // Verification failure: another source may serve a correct copy.
                    try? FileManager.default.removeItem(at: partURL)
                    lastFailure = DownloadFailure(task: task, code: error.code, message: error.message)
                    break
                } catch {
                    try? FileManager.default.removeItem(at: partURL)
                    lastFailure = DownloadFailure(task: task, code: .downloadFailed, message: error.localizedDescription)
                    break
                }
            }
        }

        progress(.fileFailed(path: task.destination.path, message: lastFailure.message))
        return .failure(lastFailure)
    }

    // MARK: - Verification and placement

    private static func verify(_ partURL: URL, task: DownloadTask, source: String) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: partURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            throw LauncherError(.downloadFailed, "Downloaded file missing after transfer: \(partURL.path)")
        }
        guard size > 0 else {
            throw LauncherError(.sizeMismatch, "Downloaded an empty file from \(source) for \(task.destination.lastPathComponent)")
        }
        if let expected = task.size, size != expected {
            throw LauncherError(
                .sizeMismatch,
                "Size mismatch for \(task.destination.lastPathComponent) from \(source): expected \(expected) bytes, got \(size)",
                suggestion: "The file was rejected and will not be used; retry or switch source."
            )
        }
        if let expected = task.sha1 {
            let actual = try SHA1.hexDigest(ofFileAt: partURL)
            guard actual == expected.lowercased() else {
                throw LauncherError(
                    .hashMismatch,
                    "SHA-1 mismatch for \(task.destination.lastPathComponent) from \(source): expected \(expected), got \(actual)",
                    suggestion: "The download was rejected; retry or switch source. A mirror that serves corrupt files is not trusted."
                )
            }
        }
    }

    private static func place(_ partURL: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: partURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw LauncherError(.ioFailure, "Cannot place \(destination.path): \(error.localizedDescription)")
        }
    }

    private static func fileSize(_ url: URL) throws -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            throw LauncherError(.ioFailure, "Cannot read size of \(url.path)")
        }
        return size
    }

    private static func makePartURL(for destination: URL) -> URL {
        let suffix = UUID().uuidString.prefix(8)
        return destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).part-\(suffix)", isDirectory: false)
    }

    private static func retryDelayNanoseconds(attempt: Int, base: TimeInterval) -> UInt64 {
        let seconds = min(5, base * Double(1 << max(0, attempt - 1)))
        return UInt64(seconds * 1_000_000_000)
    }

    // MARK: - Preflight

    private static func deduplicated(_ tasks: [DownloadTask]) -> [DownloadTask] {
        var seen = Set<String>()
        var result: [DownloadTask] = []
        for task in tasks {
            guard seen.insert(task.destination.standardizedFileURL.path).inserted else { continue }
            result.append(task)
        }
        return result
    }

    private func checkDiskSpace(for pending: [DownloadTask]) throws {
        guard !configuration.skipDiskSpaceCheck, !pending.isEmpty else { return }
        let required = pending.reduce(Int64(0)) { $0 + Int64(max(0, $1.size ?? 0)) }
        guard required > 0 else { return }
        guard let destination = pending.first?.destination else { return }
        let volumeURL = Self.volumeRoot(for: destination)
        guard let values = try? volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return
        }
        // Keep a small safety margin for metadata, logs and the .part file of the largest entry.
        let margin = Int64(32 * 1024 * 1024)
        if required + margin > available {
            throw LauncherError(
                .diskFull,
                "Not enough disk space: installation needs \(Self.format(bytes: required)), only \(Self.format(bytes: available)) available on \(volumeURL.path)",
                suggestion: "Free up space or choose a different --root."
            )
        }
    }

    private static func volumeRoot(for url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }

    public static func format(bytes: Int) -> String {
        format(bytes: Int64(bytes))
    }

    public static func format(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 bytes" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

extension TransportError {
    var launcherCode: LauncherError.Code {
        switch self {
        case .network: return .networkFailure
        case let .httpStatus(status):
            switch status {
            case 403: return .httpForbidden
            case 404: return .httpNotFound
            default: return .downloadFailed
            }
        case .localIO: return .ioFailure
        case .invalidResponse, .cancelled: return .downloadFailed
        }
    }
}
