import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import LauncherCore

final class ProcessControllerTests: XCTestCase {
    // MARK: - Normal exits

    func testEchoExitsZeroAndStreamsStdout() async throws {
        let workDirectory = try makeWorkingDirectory("process-echo")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let plan = makePlan(
            executable: "/bin/echo",
            arguments: ["hello-lingxi"],
            workingDirectory: workDirectory
        )

        let game = try await GameProcessController().start(plan)
        XCTAssertGreaterThan(game.processIdentifier, 0)

        let result = await collectEvents(from: game)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("Timed out waiting for /bin/echo to exit")
        }

        XCTAssertEqual(stdoutText(result.events), "hello-lingxi\n")
        XCTAssertEqual(stderrText(result.events), "")
        let exit = try XCTUnwrap(singleExit(in: result.events))
        XCTAssertEqual(exit.code, 0)
        XCTAssertEqual(exit.reason, .exited)
        XCTAssertNil(exit.signal)
        XCTAssertTrue(exit.isSuccess)
        XCTAssertEqual(result.events.last, .exited(exit), "The stream must finish with .exited")
    }

    func testEventStreamFinishesAfterExit() async throws {
        let workDirectory = try makeWorkingDirectory("process-stream-finish")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let plan = makePlan(executable: "/bin/echo", arguments: ["done"], workingDirectory: workDirectory)

        let game = try await GameProcessController().start(plan)
        // Consume until the stream ends on its own; a stream that never finishes would time out.
        let result = await collectEvents(from: game, stopAtExit: false)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("The event stream was never finished after the process exited")
        }

        let exit = try XCTUnwrap(singleExit(in: result.events))
        XCTAssertEqual(exit.code, 0)
        XCTAssertEqual(result.events.last, .exited(exit))
    }

    func testNonZeroExitIsAnEventNotAThrownError() async throws {
        let workDirectory = try makeWorkingDirectory("process-false")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let plan = makePlan(executable: "/usr/bin/false", workingDirectory: workDirectory)

        // `start` must not throw: a crashing or failing child is reported through the stream.
        let game = try await GameProcessController().start(plan)
        let result = await collectEvents(from: game)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("Timed out waiting for /usr/bin/false to exit")
        }

        let exit = try XCTUnwrap(singleExit(in: result.events))
        XCTAssertEqual(exit.code, 1)
        XCTAssertEqual(exit.reason, .exited)
        XCTAssertFalse(exit.isSuccess)
    }

    func testStderrIsStreamedSeparately() async throws {
        let workDirectory = try makeWorkingDirectory("process-stderr")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let missingPath = "/lingxi-does-not-exist-\(UUID().uuidString)"
        let plan = makePlan(
            executable: "/bin/ls",
            arguments: [missingPath],
            workingDirectory: workDirectory
        )

        let game = try await GameProcessController().start(plan)
        let result = await collectEvents(from: game)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("Timed out waiting for /bin/ls to exit")
        }

        XCTAssertEqual(stdoutText(result.events), "")
        XCTAssertFalse(stderrText(result.events).isEmpty, "ls must report the error on stderr")
        XCTAssertTrue(stderrText(result.events).contains(missingPath), stderrText(result.events))
        let exit = try XCTUnwrap(singleExit(in: result.events))
        XCTAssertEqual(exit.code, 1)
        XCTAssertEqual(exit.reason, .exited)
    }

    // MARK: - Large output

    func testLargeStdoutDoesNotDeadlock() async throws {
        let jot = URL(fileURLWithPath: "/usr/bin/jot")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: jot.path),
            "/usr/bin/jot is required to exercise a >1 MB stdout stream"
        )
        let workDirectory = try makeWorkingDirectory("process-large-output")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        // ~1.3 MB of output: far more than a pipe buffer, so a naive reader would deadlock.
        let plan = makePlan(executable: jot.path, arguments: ["200000"], workingDirectory: workDirectory)

        let game = try await GameProcessController().start(plan)
        let result = await collectEvents(from: game, timeout: 30)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("Reading >1 MB from stdout timed out; the pipe reader is deadlocked")
        }

        let output = stdoutText(result.events)
        XCTAssertGreaterThan(output.utf8.count, 1_000_000, "Expected the full >1 MB of output")
        XCTAssertGreaterThan(stdoutChunkCount(result.events), 1, "Output must be delivered in chunks")
        XCTAssertEqual(stderrText(result.events), "")
        let exit = try XCTUnwrap(singleExit(in: result.events))
        XCTAssertEqual(exit.code, 0)
        XCTAssertEqual(exit.reason, .exited)
    }

    // MARK: - Launch environment

    func testWorkingDirectoryIsHonoured() async throws {
        let workDirectory = try makeWorkingDirectory("process-cwd")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let plan = makePlan(executable: "/bin/pwd", workingDirectory: workDirectory)

        let game = try await GameProcessController().start(plan)
        let result = await collectEvents(from: game)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("Timed out waiting for /bin/pwd to exit")
        }

        let printed = stdoutText(result.events).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(printed.isEmpty)
        let printedURL = URL(fileURLWithPath: printed).resolvingSymlinksInPath()
        XCTAssertEqual(printedURL.path, workDirectory.resolvingSymlinksInPath().path)
        XCTAssertEqual(try XCTUnwrap(singleExit(in: result.events)).code, 0)
    }

    func testEnvironmentOverridesAreMergedIntoInheritedEnvironment() async throws {
        let workDirectory = try makeWorkingDirectory("process-env")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let plan = makePlan(
            executable: "/usr/bin/env",
            workingDirectory: workDirectory,
            environmentOverrides: ["LINGXI_TEST_ENV": "lingxi-value"]
        )

        let game = try await GameProcessController().start(plan)
        let result = await collectEvents(from: game)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("Timed out waiting for /usr/bin/env to exit")
        }

        let output = stdoutText(result.events)
        XCTAssertTrue(output.contains("LINGXI_TEST_ENV=lingxi-value"), "Override missing from: \(output)")
        XCTAssertTrue(output.contains("PATH="), "The inherited environment must be preserved")
        XCTAssertEqual(try XCTUnwrap(singleExit(in: result.events)).code, 0)
    }

    // MARK: - Termination

    func testTerminateSleepingProcessReportsCancelled() async throws {
        let workDirectory = try makeWorkingDirectory("process-terminate")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let plan = makePlan(executable: "/bin/sleep", arguments: ["30"], workingDirectory: workDirectory)

        let game = try await GameProcessController().start(plan)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let start = Date()
        await game.control.terminate()
        // Calling terminate again must be a no-op, not a signal storm or a hang.
        await game.control.terminate()
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            10,
            "terminate() must escalate to SIGKILL instead of waiting forever"
        )

        let result = await collectEvents(from: game, timeout: 10)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("The process did not report an exit after terminate()")
        }

        let exit = try XCTUnwrap(singleExit(in: result.events))
        XCTAssertEqual(exit.reason, .cancelled)
        XCTAssertEqual(exit.signal, SIGTERM)
        XCTAssertEqual(exit.code, SIGTERM)
        XCTAssertFalse(exit.isSuccess)
    }

#if !os(Windows)
    func testSignalDeathIsReportedAsSignalled() async throws {
        let workDirectory = try makeWorkingDirectory("process-signal")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let plan = makePlan(executable: "/bin/sleep", arguments: ["30"], workingDirectory: workDirectory)

        let game = try await GameProcessController().start(plan)
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Kill the child behind the controller's back, as an OOM killer would.
        kill(game.processIdentifier, SIGKILL)

        let result = await collectEvents(from: game, timeout: 10)
        guard !result.timedOut else {
            await game.control.terminate()
            return XCTFail("The process did not report its signal death")
        }

        let exit = try XCTUnwrap(singleExit(in: result.events))
        XCTAssertEqual(exit.reason, .signalled)
        XCTAssertEqual(exit.signal, SIGKILL)
        XCTAssertEqual(exit.code, SIGKILL)
        XCTAssertFalse(exit.isSuccess)
    }

    // MARK: - Launch failures

#endif
    func testStartThrowsLaunchFailedForMissingExecutable() async throws {
        let workDirectory = try makeWorkingDirectory("process-missing-exe")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let missing = workDirectory.appendingPathComponent("no-such-java").path
        let plan = makePlan(executable: missing, workingDirectory: workDirectory)

        do {
            _ = try await GameProcessController().start(plan)
            XCTFail("start must throw when the executable does not exist")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .launchFailed)
            XCTAssertTrue(error.message.contains("no-such-java"), error.message)
            XCTAssertNotNil(error.suggestion)
        } catch {
            XCTFail("Expected LauncherError, got \(error)")
        }
    }

    func testStartThrowsLaunchFailedForMissingWorkingDirectory() async throws {
        let missingDirectory = URL(fileURLWithPath: "/tmp/lingxi-no-such-dir-\(UUID().uuidString)")
        let plan = makePlan(executable: "/bin/pwd", workingDirectory: missingDirectory)

        do {
            _ = try await GameProcessController().start(plan)
            XCTFail("start must throw when the working directory does not exist")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .launchFailed)
        } catch {
            XCTFail("Expected LauncherError, got \(error)")
        }
    }

    // MARK: - Helpers

    private func makePlan(
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL,
        environmentOverrides: [String: String] = [:]
    ) -> LaunchPlan {
        LaunchPlan(
            javaExecutable: URL(fileURLWithPath: executable),
            arguments: arguments,
            redactedArguments: arguments,
            workingDirectory: workingDirectory,
            environmentOverrides: environmentOverrides,
            versionID: "test-version",
            identityMode: .localOffline
        )
    }

    private func makeWorkingDirectory(_ label: String) throws -> URL {
        try FixtureLoader.temporaryDirectory(label)
    }

    /// Consumes the event stream until `.exited` arrives (or the stream ends) or `timeout` elapses.
    private func collectEvents(
        from game: RunningGame,
        timeout: TimeInterval = 30,
        stopAtExit: Bool = true
    ) async -> (events: [GameProcessEvent], timedOut: Bool) {
        let collector = EventCollector()
        let latch = CompletionLatch()

        let consumer = Task {
            for await event in game.events {
                collector.append(event)
                if stopAtExit, case .exited = event { break }
            }
            latch.complete()
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            latch.markTimedOut()
        }

        await latch.wait()
        timer.cancel()
        consumer.cancel()
        return (collector.events, latch.didTimeOut)
    }

    private func stdoutText(_ events: [GameProcessEvent]) -> String {
        events.compactMap { event -> String? in
            if case let .stdout(text) = event { return text }
            return nil
        }.joined()
    }

    private func stderrText(_ events: [GameProcessEvent]) -> String {
        events.compactMap { event -> String? in
            if case let .stderr(text) = event { return text }
            return nil
        }.joined()
    }

    private func stdoutChunkCount(_ events: [GameProcessEvent]) -> Int {
        events.reduce(into: 0) { count, event in
            if case .stdout = event { count += 1 }
        }
    }

    private func singleExit(in events: [GameProcessEvent]) -> GameExit? {
        let exits = events.compactMap { event -> GameExit? in
            if case let .exited(exit) = event { return exit }
            return nil
        }
        XCTAssertEqual(exits.count, 1, "Expected exactly one .exited event, got \(exits.count)")
        if case .exited = events.last {
            // Expected: the stream ends with the exit event.
        } else {
            XCTFail("The event stream must finish with .exited, last event was \(String(describing: events.last))")
        }
        return exits.first
    }
}

// MARK: - Test doubles for the async stream

/// Thread-safe accumulator because the consumer task and the assertions live on different
/// executors.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GameProcessEvent] = []

    func append(_ event: GameProcessEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [GameProcessEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// One-shot completion latch with a timeout flag.
private final class CompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var timedOut = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func complete() {
        finish(timedOut: false)
    }

    func markTimedOut() {
        finish(timedOut: true)
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func finish(timedOut: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        if timedOut { self.timedOut = true }
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
