import Foundation

/// Evaluates Mojang `rules` arrays against a `PlatformContext`.
///
/// The matching semantics mirror the official launcher:
/// - `nil` or empty rules ⇒ allowed.
/// - Otherwise the result starts as disallowed and every matching rule overwrites it, so the
///   **last** matching rule wins (e.g. `[allow, disallow(osx)]` is disallowed on macOS).
/// - A rule matches only when *all* present conditions match: OS name, CPU architecture,
///   OS version regular expression, OS version range and launcher feature flags. A feature
///   absent from `PlatformContext.features` counts as `false`, never as implicitly enabled.
///
/// Unknown vocabulary (an OS name or CPU architecture that `PlatformContext` cannot map) and
/// malformed condition values (invalid regular expression, non-numeric version range) throw
/// instead of silently selecting or dropping a library: guessing platform compatibility is more
/// dangerous than refusing to launch.
public struct RuleEvaluator: RuleEvaluating {
    public init() {}

    public func isAllowed(_ rules: [Rule]?, platform: PlatformContext) throws -> Bool {
        guard let rules, !rules.isEmpty else { return true }

        var allowed = false
        for rule in rules {
            if try matches(rule, platform: platform) {
                allowed = rule.action == .allow
            }
        }
        return allowed
    }

    // MARK: - Rule matching

    private func matches(_ rule: Rule, platform: PlatformContext) throws -> Bool {
        var matched = true

        if let os = rule.os {
            // Evaluated even when an earlier condition already failed: a malformed condition is
            // a metadata bug that must be reported, not skipped because another field did not match.
            let osMatched = try matches(os, platform: platform)
            if !osMatched { matched = false }
        }

        if let features = rule.features {
            for (name, expected) in features where platform.featureEnabled(name) != expected {
                matched = false
            }
        }

        return matched
    }

    private func matches(_ os: RuleOS, platform: PlatformContext) throws -> Bool {
        var matched = true

        if let name = os.name {
            let normalized = name.lowercased()
            guard Self.supportedOSNames.contains(normalized) else {
                throw LauncherError(
                    .unsupportedVersion,
                    "Unsupported OS name '\(name)' in a rule",
                    suggestion: "LingXi Launcher only understands osx, linux and windows rules. Refusing to guess whether this rule applies."
                )
            }
            if normalized != platform.os.rawValue { matched = false }
        }

        if let arch = os.arch {
            let normalized = arch.lowercased()
            guard Self.knownArchitectures.contains(normalized) else {
                throw LauncherError(
                    .unsupportedVersion,
                    "Unsupported CPU architecture '\(arch)' in a rule",
                    suggestion: "LingXi Launcher only understands arm64/aarch64, x86_64/amd64 and x86/i386 rules. Refusing to guess whether this rule applies."
                )
            }
            let aliases = platform.architectureAliases.map { $0.lowercased() }
            if !aliases.contains(normalized) { matched = false }
        }

        if let pattern = os.version {
            let regex = try Self.compiledRegex(pattern)
            // Search, not whole-string match: real metadata uses prefixes such as `^10\.` for
            // "Windows 10", which must also match the full `10.0.17134` version string.
            let range = NSRange(platform.osVersion.startIndex..<platform.osVersion.endIndex, in: platform.osVersion)
            if regex.firstMatch(in: platform.osVersion, options: [], range: range) == nil {
                matched = false
            }
        }

        if let versionRange = os.versionRange {
            let current = try Self.numericVersion(platform.osVersion, field: "platform OS version")
            if let minimum = versionRange.min {
                let bound = try Self.numericVersion(minimum, field: "rule os.versionRange.min")
                if Self.compare(current, bound) < 0 { matched = false }
            }
            if let maximum = versionRange.max {
                let bound = try Self.numericVersion(maximum, field: "rule os.versionRange.max")
                if Self.compare(current, bound) > 0 { matched = false }
            }
        }

        return matched
    }

    // MARK: - Vocabulary

    /// OS names Mojang metadata uses. Anything else is rejected instead of guessed.
    private static let supportedOSNames: Set<String> = ["osx", "linux", "windows"]

    /// Every CPU architecture name the launcher can map onto `PlatformContext.CPUArch`.
    private static let knownArchitectures: Set<String> = [
        "arm64", "aarch64",
        "x86_64", "amd64", "x86-64",
        "x86", "i386", "i686",
    ]

    // MARK: - Regular expressions

    private static func compiledRegex(_ pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            throw LauncherError(
                .invalidMetadata,
                "Invalid os.version regular expression '\(pattern)': \(error.localizedDescription)",
                suggestion: "Fix or reinstall the version metadata; LingXi Launcher will not guess which OS versions a malformed rule matches."
            )
        }
    }

    // MARK: - Numeric version ranges

    /// Parses a dot-separated numeric version (`10.0.17134`) into comparable components.
    ///
    /// `os.versionRange` bounds and the platform OS version are both compared numerically, part
    /// by part. Non-numeric, negative or empty components are metadata errors, never `0`.
    private static func numericVersion(_ raw: String, field: String) throws -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw numericVersionError(raw, field: field)
        }
        var components: [Int] = []
        for component in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(component) else {
                throw numericVersionError(raw, field: field)
            }
            components.append(value)
        }
        return components
    }

    private static func numericVersionError(_ raw: String, field: String) -> LauncherError {
        LauncherError(
            .invalidMetadata,
            "Cannot compare \(field) '\(raw)' as a numeric dot-separated version",
            suggestion: "Only versions such as '10.0.17134' can be compared; fix the version metadata or the platform description."
        )
    }

    /// Compares two numeric component lists, padding the shorter one with zeros so
    /// `10.0` and `10.0.0` are equal.
    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}
