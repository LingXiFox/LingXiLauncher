import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Discovers the version, architecture and vendor of a local `java` executable by running it.
///
/// The probe executes the binary directly (never through `sh -c` / `bash -c`) with the
/// arguments `-XshowSettings:properties -version`. HotSpot prints that property list to
/// stderr, but wrappers and other JVMs may print it to stdout, so both streams are captured
/// and merged. All parsing is pure and exposed as static helpers so it can be unit tested
/// without a JDK.
public struct JavaRuntimeInspector: JavaRuntimeInspecting {
    /// Upper bound for the probe process. Cold JVM startup is normally well below one second.
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    // MARK: - Inspecting

    public func inspect(executable: URL) throws -> JavaRuntime {
        try Self.validateExecutable(executable)
        let probe = try Self.runProbe(executable: executable, timeout: timeout)
        return try Self.makeRuntime(executable: executable, probe: probe)
    }

    /// Returns the first known Java location whose executable answers the version probe.
    ///
    /// Only locations that actually exist and are executable are considered. Discovery runs
    /// the candidates in a fixed order and never uses a shell or the network. Callers that
    /// already know the runtime path should pass it explicitly instead of relying on this.
    public func discoverDefaultExecutable() throws -> URL {
        var failures: [String] = []
        let candidates = Self.candidateExecutablePaths()
        for candidate in candidates {
            do {
                _ = try inspect(executable: candidate)
                return candidate
            } catch let error as LauncherError {
                failures.append("\(candidate.path): \(error.message)")
            } catch {
                failures.append("\(candidate.path): \(error)")
            }
        }
        let detail = failures.isEmpty
            ? "no Java executable was found in the standard locations or on PATH"
            : failures.prefix(5).joined(separator: "; ")
        throw LauncherError(.javaNotFound, "No usable Java runtime found — \(detail)", suggestion: Self.javaSuggestion)
    }

    /// Convenience overload that probes with the default 10 second timeout.
    public static func discoverDefaultExecutable() throws -> URL {
        try JavaRuntimeInspector().discoverDefaultExecutable()
    }

    // MARK: - Pure parsing helpers

    /// Parses the major Java version out of a `java.version` value or a `-version` banner.
    ///
    /// Handles both the legacy (`1.8.0_504` ⇒ 8) and the modern (`21.0.12.1` ⇒ 21) schemes.
    /// Returns `nil` when no leading numeric component can be interpreted.
    public static func parseMajorVersion(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split { character in
            character == "." || character == "_" || character == "-" || character == "+"
        }
        guard let firstComponent = components.first, let first = Int(firstComponent) else { return nil }
        guard first == 1 else { return first }
        // Legacy scheme: "1.<major>.<minor>_<update>" (Java 1.1 – 1.8).
        guard components.count >= 2, let second = Int(components[1]) else { return nil }
        return second
    }

    /// Rosetta detection: an x86_64 JVM on physically arm64 hardware is translated.
    public static func detectRosetta(
        javaArchitecture: PlatformContext.CPUArch,
        hardwareArchitecture: PlatformContext.CPUArch
    ) -> Bool {
        hardwareArchitecture == .arm64 && javaArchitecture == .x86_64
    }

    /// Maps the JVM's `os.arch` property onto the launcher's CPU architecture model.
    public static func mapArchitecture(_ osArch: String) -> PlatformContext.CPUArch {
        switch osArch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "aarch64", "arm64":
            return .arm64
        case "x86_64", "amd64":
            return .x86_64
        case "x86", "i386", "i686":
            return .x86
        default:
            return .unknown
        }
    }

    /// The Java executables this launcher knows about, in probe order.
    ///
    /// Scans both the per-user and the system `JavaVirtualMachines` directories, the
    /// `/usr/bin/java` stub, and the directories on `PATH` (parsed without invoking a shell).
    /// Paths are standardised, de-duplicated and filtered to existing executable files.
    public static func candidateExecutablePaths() -> [URL] {
        let fileManager = FileManager.default
        var rawPaths: [String] = []

        let virtualMachineRoots = [
            "/Library/Java/JavaVirtualMachines",
            "/System/Library/Java/JavaVirtualMachines",
        ]
        for root in virtualMachineRoots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() {
                rawPaths.append("\(root)/\(entry)/Contents/Home/bin/java")
            }
        }

        rawPaths.append("/usr/bin/java")

        if let pathVariable = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathVariable.split(separator: ":") where !directory.isEmpty {
                rawPaths.append("\(directory)/java")
            }
        }

        var seen = Set<String>()
        var candidates: [URL] = []
        for rawPath in rawPaths {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            guard fileManager.isExecutableFile(atPath: url.path) else { continue }
            candidates.append(url)
        }
        return candidates
    }

    // MARK: - Validation

    private static let javaSuggestion = "Install a JDK (for example Microsoft OpenJDK 21 or Eclipse Temurin) or pass the path to a Java executable with --java."

    private static func validateExecutable(_ executable: URL) throws {
        let path = executable.path
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard !path.isEmpty, fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw LauncherError(.javaNotFound, "No Java executable at '\(path)'", suggestion: javaSuggestion)
        }
        guard !isDirectory.boolValue else {
            throw LauncherError(.javaNotFound, "'\(path)' is a directory, not a Java executable", suggestion: javaSuggestion)
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            throw LauncherError(.javaNotFound, "'\(path)' is not executable", suggestion: "Fix the file permissions (chmod +x) or pick another Java runtime with --java.")
        }
        // Reject sockets, FIFOs and devices that happen to carry an execute bit. Symlinks are
        // resolved first so a link to a regular `java` binary stays valid.
        let resolvedPath = executable.resolvingSymlinksInPath().path
        if let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath),
           let type = attributes[.type] as? FileAttributeType,
           type != .typeRegular {
            throw LauncherError(.javaNotFound, "'\(path)' is not a regular file", suggestion: javaSuggestion)
        }
    }

    // MARK: - Probing

    private struct ProbeResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private static func runProbe(executable: URL, timeout: TimeInterval) throws -> ProbeResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-XshowSettings:properties", "-version"]
        // The probe never reads stdin; an inherited terminal must not be able to block it.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ProbeCollector()
        process.terminationHandler = { _ in collector.signalTermination() }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
        }

        do {
            try process.run()
        } catch {
            throw LauncherError(
                .javaNotFound,
                "Failed to run Java executable '\(executable.path)': \(error.localizedDescription)",
                suggestion: javaSuggestion
            )
        }

        // The parent holds a copy of each write end; without closing it the readers never EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            if collector.consume(handle.availableData, isStdout: true) {
                handle.readabilityHandler = nil
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if collector.consume(handle.availableData, isStdout: false) {
                handle.readabilityHandler = nil
            }
        }

        guard collector.waitForTermination(timeout: timeout) else {
            if process.isRunning {
                process.terminate()
            }
            _ = collector.waitForTermination(timeout: 2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw LauncherError(
                .javaNotFound,
                "Java version probe timed out after \(formatted(seconds: timeout))s for '\(executable.path)'",
                suggestion: "The Java executable did not respond to -version; verify it is a working JDK or pass a different runtime with --java."
            )
        }

        // Normally both readers hit EOF immediately after exit; bound the wait so a stray
        // grandchild holding the pipes cannot block inspection forever.
        _ = collector.waitForAllEOF(timeout: 2)
        return ProbeResult(stdout: collector.stdoutData, stderr: collector.stderrData, exitCode: process.terminationStatus)
    }

    /// Thread-safe sink for the two probe streams. `readabilityHandler` callbacks arrive on
    /// Foundation's private queues, possibly concurrently, so all state is lock-protected.
    private final class ProbeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let terminated = DispatchSemaphore(value: 0)
        private let eofReceived = DispatchSemaphore(value: 0)
        private var stdout = Data()
        private var stderr = Data()

        func signalTermination() {
            terminated.signal()
        }

        /// Stores a chunk. Returns `true` when `data` was the end-of-file marker.
        func consume(_ data: Data, isStdout: Bool) -> Bool {
            if data.isEmpty {
                eofReceived.signal()
                return true
            }
            lock.lock()
            if isStdout {
                stdout.append(data)
            } else {
                stderr.append(data)
            }
            lock.unlock()
            return false
        }

        func waitForTermination(timeout: TimeInterval) -> Bool {
            terminated.wait(timeout: .now() + max(0, timeout)) == .success
        }

        func waitForAllEOF(timeout: TimeInterval) -> Bool {
            let deadline = Date(timeIntervalSinceNow: max(0, timeout))
            for _ in 0..<2 {
                let remaining = max(0, deadline.timeIntervalSinceNow)
                if eofReceived.wait(timeout: .now() + remaining) == .timedOut {
                    return false
                }
            }
            return true
        }

        var stdoutData: Data {
            lock.lock()
            defer { lock.unlock() }
            return stdout
        }

        var stderrData: Data {
            lock.lock()
            defer { lock.unlock() }
            return stderr
        }
    }

    // MARK: - Parsing

    private static func makeRuntime(executable: URL, probe: ProbeResult) throws -> JavaRuntime {
        // Java writes the property list to stderr (and occasionally stdout); merge both.
        let merged = String(decoding: probe.stdout, as: UTF8.self) + "\n" + String(decoding: probe.stderr, as: UTF8.self)
        let properties = parseProperties(in: merged)

        let versionCandidates = [properties["java.version"], versionBanner(in: merged)].compactMap { $0 }
        guard let versionString = versionCandidates.first(where: { parseMajorVersion($0) != nil }),
              let majorVersion = parseMajorVersion(versionString) else {
            throw LauncherError(
                .javaNotFound,
                "Could not parse Java version from '\(executable.path)' (exit \(probe.exitCode)). Output: \(outputSnippet(merged))",
                suggestion: "Verify the file is a real Java executable; pass another runtime with --java."
            )
        }

        let javaArchitecture = mapArchitecture(properties["os.arch"] ?? "")
        let hardware = PlatformContext.hardwareArchitecture()
        return JavaRuntime(
            executable: executable,
            versionString: versionString,
            majorVersion: majorVersion,
            architecture: javaArchitecture,
            vendor: properties["java.vendor"],
            osName: properties["os.name"],
            rawProperties: properties,
            hostArchitecture: hardware,
            isRosettaTranslated: detectRosetta(javaArchitecture: javaArchitecture, hardwareArchitecture: hardware)
        )
    }

    /// Parses the `    key = value` lines of `-XshowSettings:properties`.
    ///
    /// Continuation lines of multi-line values (for example `java.library.path`) carry no
    /// ` = ` separator and are deliberately skipped. The first occurrence of a key wins.
    private static func parseProperties(in output: String) -> [String: String] {
        var properties: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.range(of: " = ") else { continue }
            let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" "), !value.isEmpty, properties[key] == nil else { continue }
            properties[key] = value
        }
        return properties
    }

    /// Extracts the quoted version from the first `-version` banner line, e.g.
    /// `openjdk version "21.0.12.1" 2026-08-18 LTS` ⇒ `21.0.12.1`.
    private static func versionBanner(in output: String) -> String? {
        guard let keyword = output.range(of: "version \"") else { return nil }
        let remainder = output[keyword.upperBound...]
        guard let closingQuote = remainder.firstIndex(of: "\"") else { return nil }
        let candidate = String(remainder[..<closingQuote])
        return candidate.isEmpty ? nil : candidate
    }

    private static func outputSnippet(_ output: String, limit: Int = 300) -> String {
        let flattened = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " | ")
        guard !flattened.isEmpty else { return "<no output>" }
        return flattened.count <= limit ? flattened : String(flattened.prefix(limit)) + "..."
    }

    private static func formatted(seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }
}
