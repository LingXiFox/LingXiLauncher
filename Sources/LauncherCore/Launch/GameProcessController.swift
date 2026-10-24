import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Starts a `LaunchPlan` as a child `java` process and streams its output.
///
/// Design notes:
/// - stdout and stderr are read through `FileHandle.readabilityHandler`, one dispatch source
///   per pipe, so a child that writes megabytes can never fill a pipe buffer and deadlock.
/// - The event stream is finished from exactly one place (`GameProcessSession.finish`), after
///   the process has terminated *and* both pipe readers have reported EOF. That yields exactly
///   one `.exited(GameExit)` event, last, and finishes the continuation exactly once.
/// - A game crash is normal data, not a thrown error: `start` only throws when the process
///   cannot be spawned at all.
public actor GameProcessController: GameProcessControlling {
    public init() {}

    public func start(_ plan: LaunchPlan) async throws -> RunningGame {
        let process = Process()
        process.executableURL = plan.javaExecutable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory

        // Inherit the launcher environment, then apply the per-launch overrides on top.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in plan.environmentOverrides {
            environment[key] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let session = GameProcessSession(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        do {
            try process.run()
        } catch {
            throw LauncherError(
                .launchFailed,
                "Failed to start '\(plan.javaExecutable.path)' in '\(plan.workingDirectory.path)': \(error.localizedDescription)",
                suggestion: "Verify the Java executable and the game directory exist and are accessible."
            )
        }

        // Close the parent's copies of the write ends so the readers observe EOF once the child
        // (and anything it inherited the descriptors into) has exited.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        session.start()
        return RunningGame(
            processIdentifier: process.processIdentifier,
            events: session.events,
            control: session
        )
    }
}

// MARK: - One running child

/// Owns a single child process, its pipes and its event stream.
///
/// This type is deliberately not actor-isolated: the pipe callbacks and the `waitUntilExit`
/// observer run on Foundation/Dispatch threads. Mutating state is therefore guarded by
/// `lock`, and the event stream is the only cross-thread output channel.
private final class GameProcessSession: RunningGameControlling, @unchecked Sendable {
    let events: AsyncStream<GameProcessEvent>

    private let continuation: AsyncStream<GameProcessEvent>.Continuation
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let lock = NSLock()

    private struct State {
        var exit: GameExit?
        var stdoutReachedEOF = false
        var stderrReachedEOF = false
        var terminationRequested = false
        var finished = false
    }

    private var state = State()

    /// Grace period between SIGTERM and SIGKILL in `terminate()`.
    private static let terminationGracePeriod: TimeInterval = 5
    /// How long to wait for pipe EOF after the process exited before finishing the stream
    /// anyway (protects against grandchildren that inherited the pipe descriptors).
    private static let eofGracePeriod: TimeInterval = 2
    private static let exitPollInterval: UInt64 = 50_000_000

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        let pair = AsyncStream<GameProcessEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = pair.stream
        self.continuation = pair.continuation
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    /// Installs the pipe readers and starts waiting for the child to exit. Called once, right
    /// after a successful `process.run()`.
    func start() {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            readAvailableData(from: handle, isStdout: true)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            readAvailableData(from: handle, isStdout: false)
        }

        // `waitUntilExit` is called on a background queue rather than in a `terminationHandler`
        // so the exit is observed even if the process finished before any handler was set.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            process.waitUntilExit()
            processDidTerminate()
        }
    }

    // MARK: RunningGameControlling

    func terminate() async {
        if isExited { return }

        let isFirstRequest = withLock { () -> Bool in
            guard !state.terminationRequested else { return false }
            state.terminationRequested = true
            return true
        }
        guard isFirstRequest else {
            // Another caller already started the shutdown sequence; wait for it to finish
            // instead of signalling the child twice.
            _ = await waitForExit(upTo: Self.terminationGracePeriod + 2)
            return
        }

        // SIGTERM first: it lets the JVM run shutdown hooks and save its world.
        if !isExited {
            process.terminate()
        }

        if await waitForExit(upTo: Self.terminationGracePeriod) { return }

        // Escalate. The child is still unreaped, so its PID cannot have been reused by a
        // different process here; kill() may report ESRCH if it exited in the meantime, which
        // is harmless.
        if !isExited {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = await waitForExit(upTo: 2)
    }

    // MARK: Pipe reading

    /// `handle.availableData` blocks only until the dispatch source says the descriptor is
    /// readable, and returns empty data at EOF. Everything read is forwarded immediately, so
    /// the child is never back-pressured by a full pipe buffer.
    private func readAvailableData(from handle: FileHandle, isStdout: Bool) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            withLock {
                if isStdout {
                    state.stdoutReachedEOF = true
                } else {
                    state.stderrReachedEOF = true
                }
            }
            finishIfReady()
            return
        }

        // UTF-8 with replacement: a game log line split across chunk boundaries may show a
        // replacement character, but output is never dropped or reordered within a stream.
        let chunk = String(decoding: data, as: UTF8.self)
        continuation.yield(isStdout ? .stdout(chunk) : .stderr(chunk))
    }

    // MARK: Exit handling

    private func processDidTerminate() {
        let status = process.terminationStatus
        let reason = process.terminationReason
        let wasRequested = withLock { state.terminationRequested }

        let exit: GameExit
        if wasRequested {
            // The launcher asked it to stop; whether the JVM honoured SIGTERM with a normal
            // exit or died from the signal, the reason is `.cancelled`.
            let signal = reason == .uncaughtSignal ? status : nil
            exit = GameExit(code: status, reason: .cancelled, signal: signal)
        } else if reason == .uncaughtSignal {
            // Foundation reports signal deaths through `terminationReason`; on Darwin the
            // signal number is also what `terminationStatus` contains (e.g. 11 for SIGSEGV).
            exit = GameExit(code: status, reason: .signalled, signal: status)
        } else {
            exit = GameExit(code: status, reason: .exited)
        }

        withLock { state.exit = exit }
        finishIfReady()

        // If the child left a grandchild holding stdout/stderr open, EOF may never arrive.
        // Finish the stream anyway after a grace period rather than leaking it forever.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.eofGracePeriod) { [self] in
            finishAfterExitIfNeeded()
        }
    }

    /// Finishes the stream when the process has exited and both directions hit EOF, which
    /// guarantees all output events were yielded before `.exited`.
    private func finishIfReady() {
        lock.lock()
        let ready = !state.finished
            && state.exit != nil
            && state.stdoutReachedEOF
            && state.stderrReachedEOF
        let exit = state.exit
        lock.unlock()
        guard ready, let exit else { return }
        finish(with: exit)
    }

    /// Fallback used only when EOF never arrives (a grandchild kept the pipes open).
    private func finishAfterExitIfNeeded() {
        lock.lock()
        let finished = state.finished
        let exit = state.exit
        lock.unlock()
        guard !finished, let exit else { return }
        finish(with: exit)
    }

    /// The single place that emits `.exited` and finishes the stream. Safe to call from any
    /// thread and any number of times: the first caller wins, later callers are no-ops.
    private func finish(with exit: GameExit) {
        lock.lock()
        guard !state.finished else {
            lock.unlock()
            return
        }
        state.finished = true
        lock.unlock()

        // Break the Pipe -> FileHandle -> closure -> session retain cycle and cancel the
        // dispatch sources now that no more data can arrive.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        continuation.yield(.exited(exit))
        continuation.finish()
    }

    // MARK: Helpers

    private var isExited: Bool {
        withLock { state.exit != nil }
    }

    private func waitForExit(upTo timeout: TimeInterval) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if isExited { return true }
            try? await Task.sleep(nanoseconds: Self.exitPollInterval)
        }
        return isExited
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
