import XCTest
@testable import LauncherCore

final class JavaRuntimeInspectorTests: XCTestCase {
    // MARK: - Version parsing

    func testParseMajorVersionHandlesLegacyAndModernSchemes() {
        XCTAssertEqual(JavaRuntimeInspector.parseMajorVersion("1.8.0_504"), 8)
        XCTAssertEqual(JavaRuntimeInspector.parseMajorVersion("1.8.0_121-b13"), 8)
        XCTAssertEqual(JavaRuntimeInspector.parseMajorVersion("21.0.12.1"), 21)
        XCTAssertEqual(JavaRuntimeInspector.parseMajorVersion("17"), 17)
        XCTAssertEqual(JavaRuntimeInspector.parseMajorVersion("21-ea"), 21)
        XCTAssertEqual(JavaRuntimeInspector.parseMajorVersion("11.0.26+4"), 11)
        XCTAssertEqual(JavaRuntimeInspector.parseMajorVersion("  21.0.1  "), 21)
        XCTAssertEqual(JavaRuntimeInspector.parseMajorVersion("1.8"), 8)
    }

    func testParseMajorVersionRejectsNonNumericInput() {
        XCTAssertNil(JavaRuntimeInspector.parseMajorVersion(""))
        XCTAssertNil(JavaRuntimeInspector.parseMajorVersion("   "))
        XCTAssertNil(JavaRuntimeInspector.parseMajorVersion("openjdk"))
        XCTAssertNil(JavaRuntimeInspector.parseMajorVersion("version 21"))
        XCTAssertNil(JavaRuntimeInspector.parseMajorVersion("1"))
    }

    // MARK: - Architecture mapping

    func testMapArchitectureTable() {
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("aarch64"), .arm64)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("arm64"), .arm64)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("AARCH64"), .arm64)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("x86_64"), .x86_64)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("amd64"), .x86_64)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("x86"), .x86)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("i386"), .x86)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("i686"), .x86)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture("ppc64"), .unknown)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture(""), .unknown)
        XCTAssertEqual(JavaRuntimeInspector.mapArchitecture(" arm64 "), .arm64)
    }

    // MARK: - Candidate discovery

    func testCandidateExecutablePathsAreUniqueAndExecutable() {
        let candidates = JavaRuntimeInspector.candidateExecutablePaths()
        XCTAssertFalse(candidates.isEmpty, "Expected at least /usr/bin/java on macOS")
        XCTAssertEqual(Set(candidates.map(\.path)).count, candidates.count, "Candidates must be de-duplicated")
        for candidate in candidates {
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: candidate.path),
                "Candidate is not executable: \(candidate.path)"
            )
            XCTAssertTrue(
                candidate.path.hasSuffix("/bin/java") || candidate.path.hasSuffix("/java"),
                "Unexpected candidate path: \(candidate.path)"
            )
        }
        XCTAssertTrue(
            candidates.contains { $0.path == "/usr/bin/java" },
            "The system Java stub should be part of the candidate list"
        )
    }

    // MARK: - Executable validation

    func testInspectThrowsForMissingExecutable() throws {
        let directory = try FixtureLoader.temporaryDirectory("inspector-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("no-such-java")

        XCTAssertThrowsError(try JavaRuntimeInspector().inspect(executable: missing)) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .javaNotFound)
            XCTAssertTrue(launcherError.message.contains("No Java executable"), launcherError.message)
            XCTAssertNotNil(launcherError.suggestion)
        }
    }

    func testInspectThrowsForNonExecutableFile() throws {
        let directory = try FixtureLoader.temporaryDirectory("inspector-not-executable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("java")
        try FixtureLoader.write("#!/bin/sh\nexit 0\n", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        XCTAssertThrowsError(try JavaRuntimeInspector().inspect(executable: file)) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .javaNotFound)
            XCTAssertTrue(launcherError.message.contains("not executable"), launcherError.message)
        }
    }

    func testInspectThrowsForDirectory() throws {
        let directory = try FixtureLoader.temporaryDirectory("inspector-directory")
        defer { try? FileManager.default.removeItem(at: directory) }
        let subdirectory = directory.appendingPathComponent("java", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try JavaRuntimeInspector().inspect(executable: subdirectory)) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .javaNotFound)
            XCTAssertTrue(launcherError.message.contains("directory"), launcherError.message)
        }
    }

    // MARK: - Probe parsing with scripted executables

    func testInspectParsesPropertyOutputFromFakeJava() throws {
        let directory = try FixtureLoader.temporaryDirectory("inspector-properties")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeJava = try makeExecutableScript(
            in: directory,
            contents: """
            #!/bin/sh
            cat >&2 <<'JAVA_PROPERTIES'
            Property settings:
                java.version = 17.0.20.1
                java.vendor = Microsoft
                java.vendor.version = Microsoft-14941480
                os.arch = aarch64
                os.name = Mac OS X
            JAVA_PROPERTIES
            printf 'openjdk version "17.0.20.1" 2025-04-15 LTS\\n' >&2
            exit 0
            """
        )

        let runtime = try JavaRuntimeInspector(timeout: 10).inspect(executable: fakeJava)

        XCTAssertEqual(runtime.executable, fakeJava)
        XCTAssertEqual(runtime.versionString, "17.0.20.1")
        XCTAssertEqual(runtime.majorVersion, 17)
        XCTAssertEqual(runtime.vendor, "Microsoft")
        XCTAssertEqual(runtime.architecture, .arm64)
        XCTAssertEqual(runtime.osName, "Mac OS X")
        XCTAssertEqual(runtime.rawProperties["java.version"], "17.0.20.1")
        XCTAssertEqual(runtime.rawProperties["java.vendor.version"], "Microsoft-14941480")
        XCTAssertTrue(runtime.displayDescription.contains("Java 17.0.20.1"))
        XCTAssertTrue(runtime.displayDescription.contains("Microsoft"))
    }

    func testInspectFallsBackToVersionBannerWhenPropertiesAreMissing() throws {
        let directory = try FixtureLoader.temporaryDirectory("inspector-banner")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeJava = try makeExecutableScript(
            in: directory,
            contents: """
            #!/bin/sh
            printf 'openjdk version "21.0.12" 2026-08-18 LTS\\n' >&2
            exit 0
            """
        )

        let runtime = try JavaRuntimeInspector(timeout: 10).inspect(executable: fakeJava)

        XCTAssertEqual(runtime.versionString, "21.0.12")
        XCTAssertEqual(runtime.majorVersion, 21)
        XCTAssertNil(runtime.vendor)
        XCTAssertEqual(runtime.architecture, .unknown)
    }

    func testInspectThrowsWhenOutputIsNotAJavaVersion() throws {
        let directory = try FixtureLoader.temporaryDirectory("inspector-garbage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeJava = try makeExecutableScript(
            in: directory,
            contents: """
            #!/bin/sh
            echo "Unable to locate a Java Runtime." >&2
            exit 1
            """
        )

        XCTAssertThrowsError(try JavaRuntimeInspector(timeout: 10).inspect(executable: fakeJava)) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .javaNotFound)
            XCTAssertTrue(launcherError.message.contains("Could not parse Java version"), launcherError.message)
            XCTAssertTrue(launcherError.message.contains("Output:"), launcherError.message)
        }
    }

    func testInspectThrowsWhenOutputIsNotAJavaVersion_everydayBinary() {
        // /bin/echo accepts the probe arguments but produces no version information.
        let echo = URL(fileURLWithPath: "/bin/echo")
        XCTAssertThrowsError(try JavaRuntimeInspector(timeout: 10).inspect(executable: echo)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .javaNotFound)
        }
    }

    func testInspectTimesOutAndThrowsJavaNotFound() throws {
        let directory = try FixtureLoader.temporaryDirectory("inspector-timeout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeJava = try makeExecutableScript(
            in: directory,
            contents: """
            #!/bin/sh
            exec /bin/sleep 30
            """
        )

        let start = Date()
        XCTAssertThrowsError(try JavaRuntimeInspector(timeout: 0.4).inspect(executable: fakeJava)) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .javaNotFound)
            XCTAssertTrue(launcherError.message.contains("timed out"), launcherError.message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "The inspector must terminate a hung probe")
    }

    // MARK: - Real local JDK

    func testInspectLocalJavaRuntime() throws {
        let inspector = JavaRuntimeInspector(timeout: 20)
        let executable: URL
        do {
            executable = try inspector.discoverDefaultExecutable()
        } catch let error as LauncherError where error.code == .javaNotFound {
            throw XCTSkip("No usable local JDK: \(error.message)")
        }

        let runtime = try inspector.inspect(executable: executable)

        XCTAssertGreaterThanOrEqual(runtime.majorVersion, 8)
        XCTAssertFalse(runtime.versionString.isEmpty)
        XCTAssertNotEqual(runtime.architecture, .unknown)
        XCTAssertNotNil(runtime.rawProperties["java.version"])
        XCTAssertEqual(runtime.majorVersion, JavaRuntimeInspector.parseMajorVersion(runtime.versionString))
        XCTAssertFalse(runtime.displayDescription.isEmpty)
    }

    func testDiscoverDefaultExecutableReturnsAUsableRuntime() throws {
        let inspector = JavaRuntimeInspector(timeout: 20)
        let discovered: URL
        do {
            // Static convenience overload; the instance method is exercised elsewhere.
            discovered = try JavaRuntimeInspector.discoverDefaultExecutable()
        } catch let error as LauncherError where error.code == .javaNotFound {
            throw XCTSkip("No usable local JDK: \(error.message)")
        }

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: discovered.path))
        XCTAssertNoThrow(try inspector.inspect(executable: discovered))
        XCTAssertNoThrow(try inspector.discoverDefaultExecutable())
    }

    func testInspectAcceptsSymlinkToJavaBinary() throws {
        let inspector = JavaRuntimeInspector(timeout: 20)
        let realJava: URL
        do {
            realJava = try inspector.discoverDefaultExecutable()
        } catch let error as LauncherError where error.code == .javaNotFound {
            throw XCTSkip("No usable local JDK: \(error.message)")
        }

        let directory = try FixtureLoader.temporaryDirectory("inspector-symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("java")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realJava)

        let runtime = try inspector.inspect(executable: link)
        XCTAssertEqual(runtime.executable, link)
        XCTAssertEqual(runtime.majorVersion, JavaRuntimeInspector.parseMajorVersion(runtime.versionString))
    }

    // MARK: - Helpers

    @discardableResult
    private func makeExecutableScript(in directory: URL, name: String = "java", contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FixtureLoader.write(contents, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
