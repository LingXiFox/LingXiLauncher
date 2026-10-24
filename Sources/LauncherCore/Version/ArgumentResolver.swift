import Foundation

/// Expands Mojang `arguments.jvm` / `arguments.game` entries into argv elements.
///
/// Rule evaluation is delegated to an injected `RuleEvaluating`, so this type stays free of
/// platform-matching policy and can be tested without the concrete evaluator. Expansion is
/// deterministic and side-effect free: arrays are never joined, and a value that is not
/// included by a rule contributes nothing (not even an empty argument).
public struct ArgumentResolver: ArgumentResolving {
    private let ruleEvaluator: any RuleEvaluating

    public init(ruleEvaluator: any RuleEvaluating) {
        self.ruleEvaluator = ruleEvaluator
    }

    public func expand(
        _ entries: [ArgumentEntry],
        platform: PlatformContext,
        variables: [String: String],
        sensitiveKeys: Set<String>
    ) throws -> [String] {
        var result: [String] = []
        for entry in entries {
            switch entry {
            case let .argument(value):
                result.append(try substitute(value, variables: variables, sensitiveKeys: sensitiveKeys))
            case let .conditional(rules, values):
                // Every value of an allowed conditional becomes its own argv element. A denied
                // conditional contributes nothing at all and its values are not expanded, so an
                // unknown placeholder inside it must not fail the launch.
                guard try ruleEvaluator.isAllowed(rules, platform: platform) else { continue }
                for value in values {
                    result.append(try substitute(value, variables: variables, sensitiveKeys: sensitiveKeys))
                }
            }
        }
        return result
    }

    // MARK: - Placeholder substitution

    private func substitute(
        _ value: String,
        variables: [String: String],
        sensitiveKeys: Set<String>
    ) throws -> String {
        guard value.contains("${") else { return value }

        var output = String()
        output.reserveCapacity(value.count)
        var cursor = value.startIndex

        while cursor < value.endIndex, let opening = value.range(of: "${", range: cursor..<value.endIndex) {
            output.append(contentsOf: value[cursor..<opening.lowerBound])
            guard let closing = value.range(of: "}", range: opening.upperBound..<value.endIndex) else {
                throw LauncherError(
                    .invalidMetadata,
                    "Unterminated placeholder in argument '\(value)'",
                    suggestion: "Fix the version metadata: every '${' must be closed with '}'."
                )
            }
            let name = String(value[opening.upperBound..<closing.lowerBound])
            output.append(try replacement(for: name, argument: value, variables: variables, sensitiveKeys: sensitiveKeys))
            cursor = closing.upperBound
        }
        // Literal text after the last placeholder (and the whole string when nothing matched)
        // is preserved verbatim, e.g. the `/java` suffix of -Djava.library.path=... .
        output.append(contentsOf: value[cursor...])
        return output
    }

    private func replacement(
        for name: String,
        argument: String,
        variables: [String: String],
        sensitiveKeys: Set<String>
    ) throws -> String {
        if sensitiveKeys.contains(name) {
            return LauncherInfo.redactionPlaceholder
        }
        guard let value = variables[name] else {
            throw LauncherError(
                .invalidMetadata,
                "Unknown placeholder '${\(name)}' in argument '\(argument)'",
                suggestion: "Refusing to launch with a silently empty value; the version metadata references a variable LingXi Launcher does not provide."
            )
        }
        return value
    }
}
