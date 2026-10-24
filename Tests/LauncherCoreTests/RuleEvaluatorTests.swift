import Foundation
import XCTest
@testable import LauncherCore

final class RuleEvaluatorTests: XCTestCase {
    private let evaluator = RuleEvaluator()

    // MARK: - Helpers

    private func mac(
        _ osVersion: String = "14.4.1",
        architecture: PlatformContext.CPUArch = .arm64,
        features: [String: Bool] = [:]
    ) -> PlatformContext {
        PlatformContext(os: .macOS, architecture: architecture, osVersion: osVersion, features: features)
    }

    private func windows(
        _ osVersion: String = "10.0.17134",
        architecture: PlatformContext.CPUArch = .x86_64,
        features: [String: Bool] = [:]
    ) -> PlatformContext {
        PlatformContext(os: .windows, architecture: architecture, osVersion: osVersion, features: features)
    }

    private func linux(
        _ osVersion: String = "6.8.0",
        architecture: PlatformContext.CPUArch = .x86_64,
        features: [String: Bool] = [:]
    ) -> PlatformContext {
        PlatformContext(os: .linux, architecture: architecture, osVersion: osVersion, features: features)
    }

    private func allow(os: RuleOS? = nil, features: [String: Bool]? = nil) -> Rule {
        Rule(action: .allow, os: os, features: features)
    }

    private func disallow(os: RuleOS? = nil, features: [String: Bool]? = nil) -> Rule {
        Rule(action: .disallow, os: os, features: features)
    }

    private func decodedMetadata(_ fixture: String) throws -> VersionMetadata {
        try VersionMetadata.decode(from: try FixtureLoader.data("versions/\(fixture).json"))
    }

    private func conditionalRules(
        in entries: [ArgumentEntry],
        containing value: String
    ) -> [Rule]? {
        for entry in entries {
            if case let .conditional(rules, values) = entry, values.contains(value) {
                return rules
            }
        }
        return nil
    }

    // MARK: - Defaults and precedence

    func testNoRulesMeansAllowed() throws {
        XCTAssertTrue(try evaluator.isAllowed(nil, platform: mac()))
        XCTAssertTrue(try evaluator.isAllowed([], platform: mac()))
    }

    func testLastMatchingRuleWins() throws {
        let allowAll = allow()
        let disallowAll = disallow()

        XCTAssertFalse(try evaluator.isAllowed([allowAll, disallowAll], platform: mac()))
        XCTAssertTrue(try evaluator.isAllowed([disallowAll, allowAll], platform: mac()))

        // Only *matching* rules overwrite the result.
        let disallowWindows = disallow(os: RuleOS(name: "windows"))
        XCTAssertTrue(try evaluator.isAllowed([allowAll, disallowWindows], platform: mac()))
        XCTAssertFalse(try evaluator.isAllowed([allowAll, disallowWindows], platform: windows()))
        XCTAssertTrue(try evaluator.isAllowed([disallowWindows, allowAll], platform: windows()))
    }

    func testRuleWithNoConditionsMatchesEveryPlatform() throws {
        XCTAssertTrue(try evaluator.isAllowed([allow()], platform: mac()))
        XCTAssertTrue(try evaluator.isAllowed([allow()], platform: linux()))
        XCTAssertTrue(try evaluator.isAllowed([allow()], platform: windows()))
    }

    // MARK: - OS name

    func testOSNameSelectsPlatform() throws {
        let osxOnly = [allow(os: RuleOS(name: "osx"))]
        let linuxOnly = [allow(os: RuleOS(name: "linux"))]
        let windowsOnly = [allow(os: RuleOS(name: "windows"))]

        XCTAssertTrue(try evaluator.isAllowed(osxOnly, platform: mac()))
        XCTAssertFalse(try evaluator.isAllowed(osxOnly, platform: linux()))
        XCTAssertFalse(try evaluator.isAllowed(osxOnly, platform: windows()))

        XCTAssertTrue(try evaluator.isAllowed(linuxOnly, platform: linux()))
        XCTAssertFalse(try evaluator.isAllowed(linuxOnly, platform: mac()))

        XCTAssertTrue(try evaluator.isAllowed(windowsOnly, platform: windows()))
        XCTAssertFalse(try evaluator.isAllowed(windowsOnly, platform: mac()))
    }

    func testUnknownOSNameIsUnsupportedVersion() throws {
        for name in ["freebsd", "macos", ""] {
            let rules = [allow(os: RuleOS(name: name))]
            XCTAssertThrowsError(try evaluator.isAllowed(rules, platform: mac()), "name '\(name)'") { error in
                XCTAssertEqual((error as? LauncherError)?.code, .unsupportedVersion)
            }
        }
    }

    // MARK: - CPU architecture

    func testArchitectureAliasesMatchCaseInsensitively() throws {
        for arch in ["arm64", "aarch64", "AARCH64", "Arm64"] {
            XCTAssertTrue(
                try evaluator.isAllowed([allow(os: RuleOS(arch: arch))], platform: mac()),
                "arm64 platform should accept '\(arch)'"
            )
        }
        for arch in ["x86_64", "amd64", "x86-64", "X86_64"] {
            XCTAssertTrue(
                try evaluator.isAllowed([allow(os: RuleOS(arch: arch))], platform: mac(architecture: .x86_64)),
                "x86_64 platform should accept '\(arch)'"
            )
        }
        for arch in ["x86", "i386", "i686"] {
            XCTAssertTrue(
                try evaluator.isAllowed([allow(os: RuleOS(arch: arch))], platform: linux(architecture: .x86)),
                "x86 platform should accept '\(arch)'"
            )
        }
    }

    func testDifferentArchitectureDoesNotMatchInsteadOfThrowing() throws {
        XCTAssertFalse(try evaluator.isAllowed([allow(os: RuleOS(arch: "x86_64"))], platform: mac()))
        XCTAssertFalse(try evaluator.isAllowed([allow(os: RuleOS(arch: "amd64"))], platform: mac()))
        XCTAssertFalse(try evaluator.isAllowed([allow(os: RuleOS(arch: "x86"))], platform: mac()))
        XCTAssertFalse(try evaluator.isAllowed([allow(os: RuleOS(arch: "arm64"))], platform: mac(architecture: .x86_64)))
    }

    func testUnknownArchitectureIsUnsupportedVersion() throws {
        let rules = [allow(os: RuleOS(arch: "sparc"))]
        XCTAssertThrowsError(try evaluator.isAllowed(rules, platform: mac())) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .unsupportedVersion)
        }
    }

    func testUnknownPlatformArchitectureMatchesNoArchRule() throws {
        let rules = [allow(os: RuleOS(arch: "arm64"))]
        XCTAssertFalse(try evaluator.isAllowed(rules, platform: mac(architecture: .unknown)))
    }

    // MARK: - OS version regex

    func testOSVersionRegexUsesSearchSemantics() throws {
        // Official metadata uses prefixes (`^10\.`) to mean "Windows 10.x", so a match anywhere
        // in the version string counts; full anchoring stays possible with `$`.
        XCTAssertTrue(try evaluator.isAllowed([allow(os: RuleOS(name: "osx", version: "^14\\."))], platform: mac("14.4.1")))
        XCTAssertFalse(try evaluator.isAllowed([allow(os: RuleOS(name: "osx", version: "^13\\."))], platform: mac("14.4.1")))
        XCTAssertTrue(try evaluator.isAllowed([allow(os: RuleOS(name: "windows", version: "^10\\."))], platform: windows("10.0.17134")))
        XCTAssertTrue(try evaluator.isAllowed([allow(os: RuleOS(name: "windows", version: "10\\.0$"))], platform: windows("10.0")))
        XCTAssertFalse(try evaluator.isAllowed([allow(os: RuleOS(name: "windows", version: "10\\.0$"))], platform: windows("10.0.17134")))
    }

    func testInvalidOSVersionRegexIsInvalidMetadata() throws {
        for pattern in ["([a-z", "*broken", "\\"] {
            let rules = [allow(os: RuleOS(name: "osx", version: pattern))]
            XCTAssertThrowsError(try evaluator.isAllowed(rules, platform: mac()), "pattern '\(pattern)'") { error in
                let launcherError = error as? LauncherError
                XCTAssertEqual(launcherError?.code, .invalidMetadata)
                XCTAssertTrue(launcherError?.message.contains("regular expression") ?? false, launcherError?.message ?? "")
            }
        }
    }

    func testInvalidRegexIsRejectedEvenWhenAnotherConditionAlreadyFailed() throws {
        // A rule for a foreign OS must still be validated: malformed metadata is never skipped.
        let rules = [allow(os: RuleOS(name: "windows", version: "(["))]
        XCTAssertThrowsError(try evaluator.isAllowed(rules, platform: mac())) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }

    // MARK: - OS version range

    private func rangeRule(min: String? = nil, max: String? = nil) -> Rule {
        allow(os: RuleOS(name: "windows", versionRange: VersionRange(min: min, max: max)))
    }

    func testVersionRangeBoundsAreInclusiveAndNumeric() throws {
        let platform = windows("10.0.17134")

        XCTAssertTrue(try evaluator.isAllowed([rangeRule(min: "10.0.17134")], platform: platform))
        XCTAssertTrue(try evaluator.isAllowed([rangeRule(max: "10.0.17134")], platform: platform))
        XCTAssertTrue(try evaluator.isAllowed([rangeRule(min: "10.0.17134", max: "10.0.17134")], platform: platform))

        XCTAssertFalse(try evaluator.isAllowed([rangeRule(min: "10.0.17135")], platform: platform))
        XCTAssertFalse(try evaluator.isAllowed([rangeRule(max: "10.0.17133")], platform: platform))

        // Numeric comparison part-by-part, not lexicographic and not string equality.
        XCTAssertTrue(try evaluator.isAllowed([rangeRule(min: "10.0")], platform: platform))
        XCTAssertTrue(try evaluator.isAllowed([rangeRule(min: "9.9.99999")], platform: platform))
        XCTAssertFalse(try evaluator.isAllowed([rangeRule(min: "10.0.17134.1")], platform: platform))
        XCTAssertTrue(try evaluator.isAllowed([rangeRule(max: "10.0.17134.0")], platform: platform))
        XCTAssertTrue(try evaluator.isAllowed([rangeRule()], platform: platform))
    }

    func testVersionRangeOnOtherPlatformDoesNotMatch() throws {
        let rules = [rangeRule(min: "10.0")]
        XCTAssertFalse(try evaluator.isAllowed(rules, platform: mac()))
    }

    func testUnparseableVersionRangeIsInvalidMetadata() throws {
        for rule in [rangeRule(min: "banana"), rangeRule(max: "10.x"), rangeRule(min: "10..0"), rangeRule(max: "10.0.-1")] {
            XCTAssertThrowsError(try evaluator.isAllowed([rule], platform: windows("10.0.17134"))) { error in
                XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
            }
        }

        // The platform version itself must be numeric when a range is present.
        XCTAssertThrowsError(try evaluator.isAllowed([rangeRule(min: "10.0")], platform: windows("unknown"))) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
        // ... but not when no range condition exists.
        XCTAssertTrue(try evaluator.isAllowed([allow(os: RuleOS(name: "windows"))], platform: windows("unknown")))
    }

    // MARK: - Features

    func testFeatureConditionsRequireExplicitTrue() throws {
        let demo = [allow(features: ["is_demo_user": true])]

        XCTAssertFalse(try evaluator.isAllowed(demo, platform: mac()))
        XCTAssertTrue(try evaluator.isAllowed(demo, platform: mac(features: ["is_demo_user": true])))
        XCTAssertFalse(try evaluator.isAllowed(demo, platform: mac(features: ["is_demo_user": false])))
        XCTAssertFalse(try evaluator.isAllowed(demo, platform: mac(features: ["has_custom_resolution": true])))
    }

    func testAbsentFeatureCountsAsFalse() throws {
        // A rule that requires the feature to be *disabled* matches when the feature is absent.
        let noCustomResolution = [allow(features: ["has_custom_resolution": false])]
        XCTAssertTrue(try evaluator.isAllowed(noCustomResolution, platform: mac()))
        XCTAssertFalse(try evaluator.isAllowed(noCustomResolution, platform: mac(features: ["has_custom_resolution": true])))
    }

    func testAllFeatureEntriesMustMatch() throws {
        let rule = disallow(features: ["is_demo_user": true, "has_quick_plays_support": true])
        let allowAll = allow()

        // Only one of the two features enabled: the disallow rule does not match, allow survives.
        XCTAssertTrue(try evaluator.isAllowed([allowAll, rule], platform: mac(features: ["is_demo_user": true])))
        XCTAssertFalse(try evaluator.isAllowed(
            [allowAll, rule],
            platform: mac(features: ["is_demo_user": true, "has_quick_plays_support": true])
        ))
    }

    func testOSAndFeatureConditionsAreCombined() throws {
        let osxDemo = [allow(os: RuleOS(name: "osx"), features: ["is_demo_user": true])]
        XCTAssertTrue(try evaluator.isAllowed(osxDemo, platform: mac(features: ["is_demo_user": true])))
        XCTAssertFalse(try evaluator.isAllowed(osxDemo, platform: mac()))
        XCTAssertFalse(try evaluator.isAllowed(osxDemo, platform: linux(features: ["is_demo_user": true])))
    }

    // MARK: - Real Mojang metadata

    func testRealMetadataRuleFilteringForMacOS() throws {
        let platform = mac()

        let modern = try decodedMetadata("26.3")
        let allowedModern = try modern.libraries.filter { try evaluator.isAllowed($0.rules, platform: platform) }
        XCTAssertEqual(allowedModern.count, 80)
        XCTAssertTrue(allowedModern.contains { $0.name == "com.mojang:jtracy:1.14.38:natives-macos-arm64" })
        XCTAssertTrue(allowedModern.contains { $0.name == "com.mojang:jtracy:1.14.38:natives-macos" })
        XCTAssertFalse(allowedModern.contains { $0.name.hasSuffix(":natives-linux") })
        XCTAssertFalse(allowedModern.contains { $0.name.hasSuffix(":natives-windows") })
        XCTAssertTrue(allowedModern.contains { $0.name == "ca.weblite:java-objc-bridge:1.1" })

        let legacy = try decodedMetadata("1.16.5")
        let allowedLegacy = try legacy.libraries.filter { try evaluator.isAllowed($0.rules, platform: platform) }
        XCTAssertEqual(allowedLegacy.count, 43)
        // 1.16 metadata uses the allow-all / disallow-osx pair; the osx-specific 3.2.1 entries win.
        XCTAssertTrue(allowedLegacy.contains { $0.name == "org.lwjgl:lwjgl:3.2.1" })
        XCTAssertFalse(allowedLegacy.contains { $0.name == "org.lwjgl:lwjgl:3.2.2" })

        let mid = try decodedMetadata("1.20.1")
        let allowedMid = try mid.libraries.filter { try evaluator.isAllowed($0.rules, platform: platform) }
        XCTAssertEqual(allowedMid.count, 58)
    }

    func testRealMetadataRuleFilteringForLinuxAndWindows() throws {
        let linuxMetadata = try decodedMetadata("26.3")
        let allowedLinux = try linuxMetadata.libraries.filter { try evaluator.isAllowed($0.rules, platform: linux()) }
        XCTAssertEqual(allowedLinux.count, 66)
        XCTAssertTrue(allowedLinux.contains { $0.name.hasSuffix(":natives-linux") })
        XCTAssertFalse(allowedLinux.contains { $0.name.hasSuffix(":natives-macos") })

        let windowsMetadata = try decodedMetadata("26.3")
        let allowedWindows = try windowsMetadata.libraries.filter { try evaluator.isAllowed($0.rules, platform: windows()) }
        XCTAssertEqual(allowedWindows.count, 74)
        XCTAssertFalse(allowedWindows.contains { $0.name.hasSuffix(":natives-macos") })
        XCTAssertFalse(allowedWindows.contains { $0.name.hasSuffix(":natives-linux") })
    }

    /// 26.x metadata keeps its launcher default flags in `arguments.default-user-jvm`, which is
    /// not part of `VersionMetadata`; decode that array directly from the fixture.
    private struct DefaultUserJVMFixture: Decodable {
        struct Arguments: Decodable {
            let entries: [ArgumentEntry]

            enum CodingKeys: String, CodingKey {
                case entries = "default-user-jvm"
            }
        }

        let arguments: Arguments
    }

    func testRealMetadataVersionRangeArguments() throws {
        let fixture = try JSONDecoder().decode(
            DefaultUserJVMFixture.self,
            from: try FixtureLoader.data("versions/26.3.json")
        )
        let jvm = fixture.arguments.entries

        let zgcRules = try XCTUnwrap(conditionalRules(in: jvm, containing: "-XX:+UseZGC"))
        XCTAssertFalse(try evaluator.isAllowed(zgcRules, platform: windows("10.0.17133")))
        XCTAssertTrue(try evaluator.isAllowed(zgcRules, platform: windows("10.0.17134")))
        XCTAssertTrue(try evaluator.isAllowed(zgcRules, platform: windows("10.0.17135")))

        let g1Rules = try XCTUnwrap(conditionalRules(in: jvm, containing: "-XX:+UnlockExperimentalVMOptions"))
        XCTAssertTrue(try evaluator.isAllowed(g1Rules, platform: windows("10.0.17134")))
        XCTAssertFalse(try evaluator.isAllowed(g1Rules, platform: windows("10.0.17135")))
        XCTAssertFalse(try evaluator.isAllowed(g1Rules, platform: mac()))
    }

    func testRealMetadataFeatureGatedArguments() throws {
        let metadata = try decodedMetadata("26.3")
        let game = try XCTUnwrap(metadata.arguments?.game)
        let widthRules = try XCTUnwrap(conditionalRules(in: game, containing: "--width"))

        XCTAssertFalse(try evaluator.isAllowed(widthRules, platform: mac()))
        XCTAssertTrue(try evaluator.isAllowed(widthRules, platform: mac(features: ["has_custom_resolution": true])))

        let quickPlayRules = try XCTUnwrap(conditionalRules(in: game, containing: "--quickPlaySingleplayer"))
        XCTAssertFalse(try evaluator.isAllowed(quickPlayRules, platform: mac()))
        XCTAssertTrue(try evaluator.isAllowed(
            quickPlayRules,
            platform: mac(features: ["is_quick_play_singleplayer": true])
        ))
    }
}
