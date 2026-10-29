import XCTest
@testable import LauncherCore

final class CrashDiagnosticsTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-m73-crash")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testFabricMissingRequiredDependencyIsRootCause() throws {
        let report = analyze("""
        [main/ERROR] Missing or unsupported mandatory dependencies:
        \t- Mod 'Sodium' requires 'fabric-api' which is not installed
        """)
        XCTAssertEqual(report.diagnostics.first?.category, .missingRequiredMod)
        XCTAssertEqual(report.diagnostics.first?.isRootCause, true)
        XCTAssertTrue(report.summary.contains("缺少必需模组"))
        XCTAssertTrue(report.diagnostics.first?.evidence.isEmpty == false)
    }

    func testNeoForgeModConflictIsDetectedAndDeduplicated() throws {
        let report = analyze("""
        [main/ERROR] Mod resolution encountered an incompatible mods set:
        [main/ERROR] duplicate mods: examplemod 1.0 and examplemod 2.0
        """, exitCode: 1)
        XCTAssertEqual(report.diagnostics.filter { $0.category == .modVersionConflict }.count, 1)
        XCTAssertEqual(report.diagnostics.first?.category, .modVersionConflict)
        XCTAssertTrue(report.abnormalExit)
    }

    func testJavaVersionAndLwjglErrorsAreClassified() throws {
        let report = analyze("""
        java.lang.UnsupportedClassVersionError: net/fabricmc/loader/impl/launch/server/FabricServerLauncher has been compiled by a more recent version
        java.lang.UnsatisfiedLinkError: Failed to load library 'lwjgl'
        """, exitCode: 1)
        let categories = Set(report.diagnostics.map(\.category))
        XCTAssertTrue(categories.contains(.javaVersion))
        XCTAssertTrue(categories.contains(.lwjglNative))
        XCTAssertEqual(report.rootCause?.category, .javaVersion)
    }

    func testOpenGLAndShaderCompileErrorsAreClassified() throws {
        let report = analyze("""
        GLFW error 65542: The driver does not appear to support OpenGL
        Iris: Shader compilation failed for Complementary
        """)
        let categories = Set(report.diagnostics.map(\.category))
        XCTAssertTrue(categories.contains(.openGL))
        XCTAssertTrue(categories.contains(.irisShader))
    }

    func testUnknownLogNeverFabricatesACause() throws {
        let report = analyze("ordinary startup output\nno known signature", exitCode: 1)
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertEqual(report.diagnostics.first?.category, .unknown)
        XCTAssertEqual(report.diagnostics.first?.confidence, .low)
        XCTAssertTrue(report.summary.contains("原因未知"))
    }

    func testNormalLogWithoutKnownSignatureIsNotAbnormal() throws {
        let report = analyze("Minecraft 1.20.1 initialized", exitCode: 0)
        XCTAssertFalse(report.abnormalExit)
        XCTAssertNil(report.rootCauseID)
        XCTAssertEqual(report.diagnostics.first?.category, .unknown)
    }

    func testExportRedactsTokensAndUserPaths() throws {
        let report = analyze("""
        java.lang.OutOfMemoryError: Java heap space
        access_token=super-secret-value
        Authorization: Bearer abc.def.ghi
        world at /Users/lingxi/Library/Application Support/minecraft/saves/world
        """, exitCode: 1)
        let markdown = CrashReportExporter.markdown(for: report)
        let json = try CrashReportExporter.json(for: report)
        let jsonText = String(decoding: json, as: UTF8.self)
        for output in [markdown, jsonText] {
            XCTAssertFalse(output.contains("super-secret-value"))
            XCTAssertFalse(output.contains("abc.def.ghi"))
            XCTAssertFalse(output.contains("/Users/lingxi/"))
            XCTAssertTrue(output.contains("<redacted>") || output.contains("redacted"))
        }
    }

    func testCollectorOnlyUsesLogsBoundToTheRequestedInstance() throws {
        let repository = InstanceRepository(layout: layout)
        let first = try repository.create(id: "instance-a", displayName: "A", versionID: "1.20.1")
        let second = try repository.create(id: "instance-b", displayName: "B", versionID: "1.20.1")
        let logs = layout.launcherLogsDirectory
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let firstLog = logs.appendingPathComponent("a.log")
        let secondLog = logs.appendingPathComponent("b.log")
        try Data("# LingXi Launcher\n# instance: instance-a\n[launcher] exited code=1\njava.lang.OutOfMemoryError: Java heap space\n".utf8).write(to: firstLog)
        try Data("# LingXi Launcher\n# instance: instance-b\nGLFW error 65542: The driver does not appear to support OpenGL\n".utf8).write(to: secondLog)

        let service = CrashDiagnosticsService(layout: layout)
        let report = try service.collect(instanceID: first.id)
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertTrue(report.diagnostics.contains { $0.category == .outOfMemory })
        XCTAssertFalse(report.diagnostics.contains { $0.category == .openGL })
        XCTAssertTrue(report.logs.allSatisfy { $0.name == "a.log" })
        XCTAssertNotNil(second.id)
    }

    func testCollectorUsesLatestLogAndCrashReportWithinInstance() throws {
        let repository = InstanceRepository(layout: layout)
        let instance = try repository.create(id: "crash-instance", displayName: "Crash", versionID: "1.20.1")
        let logs = instance.gameDirectory.appendingPathComponent("logs", isDirectory: true)
        let crashes = instance.gameDirectory.appendingPathComponent("crash-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        try Data("latest log\n".utf8).write(to: logs.appendingPathComponent("latest.log"))
        try Data("---- Minecraft Crash Report ----\njava.lang.OutOfMemoryError: Java heap space\n".utf8)
            .write(to: crashes.appendingPathComponent("crash-2026-01-01.txt"))

        let report = try CrashDiagnosticsService(layout: layout).collect(instanceID: instance.id)
        XCTAssertTrue(report.abnormalExit)
        XCTAssertEqual(report.logs.map(\.kind).contains(.crashReport), true)
        XCTAssertEqual(report.rootCause?.category, .outOfMemory)
    }

    private func analyze(_ text: String, exitCode: Int32? = nil) -> CrashDiagnosticReport {
        CrashDiagnosticsService(layout: layout).analyze(
            instanceID: "test",
            logs: [CrashLogText(kind: .latestLog, name: "latest.log", text: text)],
            exitCode: exitCode
        )
    }
}
