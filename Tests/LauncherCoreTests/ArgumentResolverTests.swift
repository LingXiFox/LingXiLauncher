import XCTest
@testable import LauncherCore

/// Minimal rule evaluator used only by the T06 tests.
///
/// The production `RuleEvaluator` is written concurrently by another teammate, so the tests
/// deliberately never reference it. Needed semantics: no rules ⇒ allowed, last matching rule
/// wins, and OS name / CPU architecture aliases / launcher feature flags take part in matching.
struct T06TestRuleEvaluator: RuleEvaluating {
    func isAllowed(_ rules: [Rule]?, platform: PlatformContext) throws -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules where matches(rule, platform: platform) {
            allowed = rule.action == .allow
        }
        return allowed
    }

    private func matches(_ rule: Rule, platform: PlatformContext) -> Bool {
        if let os = rule.os {
            if let name = os.name, name != platform.os.rawValue { return false }
            if let arch = os.arch, !platform.architectureAliases.contains(arch) { return false }
            // The fixtures only constrain os.version / os.versionRange on Windows; this stub
            // does not parse them and treats such a rule as non-matching on macOS.
            if platform.os == .macOS, os.version != nil || os.versionRange != nil { return false }
        }
        if let features = rule.features {
            for (name, expected) in features where platform.featureEnabled(name) != expected {
                return false
            }
        }
        return true
    }
}

final class ArgumentResolverTests: XCTestCase {
    private let resolver = ArgumentResolver(ruleEvaluator: T06TestRuleEvaluator())
    private let macOS = PlatformContext(os: .macOS, architecture: .arm64, osVersion: "14.5.0")
    private let windows = PlatformContext(os: .windows, architecture: .x86_64, osVersion: "10.0.19045")

    // MARK: - Ordering and array expansion

    func testExpandsPlainStringEntriesInMetadataOrder() throws {
        let entries: [ArgumentEntry] = [
            .argument("-Xms2G"),
            .argument("-cp"),
            .argument("${classpath}"),
        ]
        let result = try resolver.expand(
            entries,
            platform: macOS,
            variables: ["classpath": "a.jar:b.jar"],
            sensitiveKeys: []
        )
        XCTAssertEqual(result, ["-Xms2G", "-cp", "a.jar:b.jar"])
    }

    func testMixedPlainAndConditionalEntriesExpandInExactOrder() throws {
        let entries: [ArgumentEntry] = [
            .argument("--username"),
            .argument("${auth_player_name}"),
            .conditional(rules: [], values: ["--width", "${resolution_width}", "--height", "${resolution_height}"]),
            .argument("--version"),
            .argument("${version_name}"),
        ]
        let variables = [
            "auth_player_name": "Steve",
            "resolution_width": "1280",
            "resolution_height": "720",
            "version_name": "1.20.1",
        ]
        let result = try resolver.expand(entries, platform: macOS, variables: variables, sensitiveKeys: [])
        XCTAssertEqual(
            result,
            ["--username", "Steve", "--width", "1280", "--height", "720", "--version", "1.20.1"]
        )
    }

    func testArrayValuesAreNeverJoinedOrSplit() throws {
        let entries: [ArgumentEntry] = [
            .conditional(rules: [], values: ["--jvm-arg", "-Dname=has spaces and: colons"]),
        ]
        let result = try resolver.expand(entries, platform: macOS, variables: [:], sensitiveKeys: [])
        XCTAssertEqual(result, ["--jvm-arg", "-Dname=has spaces and: colons"])
    }

    func testOSRuleIsEvaluatedAgainstTheGivenPlatform() throws {
        let rules = [Rule(action: .allow, os: RuleOS(name: "osx"))]
        let entries: [ArgumentEntry] = [.conditional(rules: rules, values: ["-XstartOnFirstThread"])]
        XCTAssertEqual(
            try resolver.expand(entries, platform: macOS, variables: [:], sensitiveKeys: []),
            ["-XstartOnFirstThread"]
        )
        XCTAssertEqual(
            try resolver.expand(entries, platform: windows, variables: [:], sensitiveKeys: []),
            []
        )
    }

    // MARK: - Rule gating

    func testDeniedConditionalContributesNothingAndKeepsSurroundingOrder() throws {
        let rules = [Rule(action: .allow, features: ["is_demo_user": true])]
        let entries: [ArgumentEntry] = [
            .argument("--before"),
            .conditional(rules: rules, values: ["--demo"]),
            .argument("--after"),
        ]
        let result = try resolver.expand(entries, platform: macOS, variables: [:], sensitiveKeys: [])
        XCTAssertEqual(result, ["--before", "--after"])
    }

    func testAllowedConditionalIncludesEveryValueWhenFeatureIsEnabled() throws {
        let rules = [
            Rule(action: .allow, features: ["has_custom_resolution": true]),
        ]
        let platform = PlatformContext(
            os: .macOS,
            architecture: .arm64,
            osVersion: "14.5.0",
            features: ["has_custom_resolution": true]
        )
        let entries: [ArgumentEntry] = [
            .argument("--before"),
            .conditional(rules: rules, values: ["--width", "${resolution_width}", "--height", "${resolution_height}"]),
            .argument("--after"),
        ]
        let result = try resolver.expand(
            entries,
            platform: platform,
            variables: ["resolution_width": "1280", "resolution_height": "720"],
            sensitiveKeys: []
        )
        XCTAssertEqual(result, ["--before", "--width", "1280", "--height", "720", "--after"])
    }

    func testDeniedConditionalDoesNotExpandItsValues() throws {
        // An unknown placeholder inside a denied conditional must never fail the launch: the
        // values are not part of argv at all.
        let rules = [Rule(action: .allow, features: ["is_demo_user": true])]
        let entries: [ArgumentEntry] = [
            .argument("--safe"),
            .conditional(rules: rules, values: ["${not_provided_anywhere}"]),
        ]
        let result = try resolver.expand(entries, platform: macOS, variables: [:], sensitiveKeys: [])
        XCTAssertEqual(result, ["--safe"])
    }

    // MARK: - Placeholder substitution

    func testSubstitutesPlaceholdersAndPreservesSurroundingLiteralText() throws {
        let variables = [
            "natives_directory": "/tmp/libraries/natives",
            "assets_root": "/tmp/assets",
            "game_directory": "/tmp/instance/.minecraft",
        ]
        let entries: [ArgumentEntry] = [
            .argument("-Djava.library.path=${natives_directory}/java"),
            .argument("--paths=${assets_root}:${game_directory}"),
            .argument("--literal"),
        ]
        let result = try resolver.expand(entries, platform: macOS, variables: variables, sensitiveKeys: [])
        XCTAssertEqual(
            result,
            [
                "-Djava.library.path=/tmp/libraries/natives/java",
                "--paths=/tmp/assets:/tmp/instance/.minecraft",
                "--literal",
            ]
        )
    }

    func testSensitiveKeyIsRedactedWhileOtherIdentityValuesStayVisible() throws {
        let variables = [
            "auth_access_token": "real-session-token",
            "auth_uuid": "069a79f444e94726a5befca90e38aaf5",
            "clientid": "0",
        ]
        let entries: [ArgumentEntry] = [
            .argument("--accessToken"),
            .argument("${auth_access_token}"),
            .argument("--uuid"),
            .argument("${auth_uuid}"),
            .argument("--clientId"),
            .argument("${clientid}"),
        ]
        let result = try resolver.expand(
            entries,
            platform: macOS,
            variables: variables,
            sensitiveKeys: ["auth_access_token"]
        )
        XCTAssertEqual(
            result,
            [
                "--accessToken",
                LauncherInfo.redactionPlaceholder,
                "--uuid",
                "069a79f444e94726a5befca90e38aaf5",
                "--clientId",
                "0",
            ]
        )
        XCTAssertFalse(result.contains("real-session-token"))
    }

    func testSensitiveKeyIsRedactedEvenWhenNoVariableIsProvided() throws {
        let result = try resolver.expand(
            [.argument("${auth_access_token}")],
            platform: macOS,
            variables: [:],
            sensitiveKeys: ["auth_access_token"]
        )
        XCTAssertEqual(result, [LauncherInfo.redactionPlaceholder])
    }

    func testUnknownPlaceholderIsInvalidMetadataNamingPlaceholderAndArgument() throws {
        let argument = "--broken=${not_a_variable}"
        XCTAssertThrowsError(
            try resolver.expand([.argument(argument)], platform: macOS, variables: [:], sensitiveKeys: [])
        ) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .invalidMetadata)
            XCTAssertTrue(launcherError.message.contains("${not_a_variable}"), launcherError.message)
            XCTAssertTrue(launcherError.message.contains(argument), launcherError.message)
        }
    }

    func testUnterminatedPlaceholderIsInvalidMetadata() throws {
        XCTAssertThrowsError(
            try resolver.expand([.argument("--broken=${open")], platform: macOS, variables: [:], sensitiveKeys: [])
        ) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .invalidMetadata)
            XCTAssertTrue(launcherError.message.contains("Unterminated"), launcherError.message)
        }
    }

    func testConditionalValuesAreAlsoSubstituted() throws {
        let entries: [ArgumentEntry] = [
            .conditional(rules: [], values: ["--assetsDir", "${assets_root}"]),
        ]
        let result = try resolver.expand(
            entries,
            platform: macOS,
            variables: ["assets_root": "/tmp/assets"],
            sensitiveKeys: []
        )
        XCTAssertEqual(result, ["--assetsDir", "/tmp/assets"])
    }
}
