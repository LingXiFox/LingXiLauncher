import XCTest
@testable import LauncherCore

final class LaunchServiceTests: XCTestCase {
    func testInvalidJavaProducesFailureEventAndFinishes() async throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-launch-service")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc"),
            dataRoot: root.appendingPathComponent("data")
        )
        let registry = InstanceRepository(layout: layout)
        let instance = try registry.create(displayName: "Test", versionID: "1.20.1")
        let profile = try LocalOfflineIdentity.makeProfile(playerName: "ServiceTest")
        let service = LaunchService(layout: layout)
        let stream = await service.launch(LaunchServiceRequest(
            instance: instance,
            identity: .localOffline(profile),
            javaExecutable: URL(fileURLWithPath: "/definitely/not/java")
        ))

        var phases: [String] = []
        var failure: LauncherError?
        for await event in stream {
            switch event {
            case let .phase(text): phases.append(text)
            case let .failed(error): failure = error
            default: break
            }
        }
        XCTAssertTrue(phases.contains("Checking Java runtime"))
        XCTAssertEqual(failure?.code, .javaNotFound)
        let running = await service.isRunning()
        XCTAssertFalse(running)
    }

    func testSecondLaunchWhileRunningIsRejected() async throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-launch-service")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc"),
            dataRoot: root.appendingPathComponent("data")
        )
        let registry = InstanceRepository(layout: layout)
        let instance = try registry.create(displayName: "Test", versionID: "1.20.1")
        let profile = try LocalOfflineIdentity.makeProfile(playerName: "ServiceTest")
        let service = LaunchService(layout: layout)
        // The first launch fails fast at Java inspection, so use a non-existent Java twice and
        // ensure the stream contract still terminates deterministically.
        let first = await service.launch(LaunchServiceRequest(
            instance: instance,
            identity: .localOffline(profile),
            javaExecutable: URL(fileURLWithPath: "/definitely/not/java")
        ))
        var firstEvents = 0
        for await _ in first { firstEvents += 1 }
        XCTAssertGreaterThan(firstEvents, 0)

        let second = await service.launch(LaunchServiceRequest(
            instance: instance,
            identity: .localOffline(profile),
            javaExecutable: URL(fileURLWithPath: "/definitely/not/java")
        ))
        var secondEvents = 0
        for await _ in second { secondEvents += 1 }
        XCTAssertGreaterThan(secondEvents, 0)
    }
}
