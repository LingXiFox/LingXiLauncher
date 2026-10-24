import Foundation
import LauncherCore

/// Minimal hand-rolled argument parser.
///
/// The launcher deliberately has zero third-party dependencies, so this replaces
/// swift-argument-parser. It is intentionally small: value options (`--key value` or
/// `--key=value`) and boolean flags, with an explicit allow list per command so a typo is a
/// usage error instead of being silently ignored.
struct CommandLineInput {
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    func value(_ name: String) -> String? { options[name] }
    func has(_ name: String) -> Bool { flags.contains(name) }

    func requireValue(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw LauncherError(.usageError, "Missing required option --\(name)")
        }
        return value
    }
}

enum ArgumentParser {
    struct Spec {
        let valueOptions: Set<String>
        let flagOptions: Set<String>

        init(valueOptions: Set<String> = [], flagOptions: Set<String> = ["json", "help"]) {
            self.valueOptions = valueOptions
            self.flagOptions = flagOptions
        }
    }

    static func parse(_ arguments: [String], spec: Spec) throws -> CommandLineInput {
        var input = CommandLineInput()
        var index = 0
        var positionalOnly = false
        while index < arguments.count {
            let token = arguments[index]
            if positionalOnly {
                input.positionals.append(token)
                index += 1
                continue
            }
            if token == "--" {
                positionalOnly = true
                index += 1
                continue
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                let name: String
                var inlineValue: String?
                if let separator = body.firstIndex(of: "=") {
                    name = String(body[body.startIndex..<separator])
                    inlineValue = String(body[body.index(after: separator)...])
                } else {
                    name = body
                }
                if spec.flagOptions.contains(name) {
                    guard inlineValue == nil else {
                        throw LauncherError(.usageError, "Option --\(name) does not take a value")
                    }
                    input.flags.insert(name)
                    index += 1
                    continue
                }
                guard spec.valueOptions.contains(name) else {
                    throw LauncherError(.usageError, "Unknown option --\(name)", suggestion: "Run `lingxi help` for the supported options.")
                }
                if let inlineValue {
                    input.options[name] = inlineValue
                    index += 1
                } else {
                    guard index + 1 < arguments.count else {
                        throw LauncherError(.usageError, "Option --\(name) requires a value")
                    }
                    input.options[name] = arguments[index + 1]
                    index += 2
                }
                continue
            }
            if token == "-h" {
                input.flags.insert("help")
                index += 1
                continue
            }
            if token == "-V" {
                input.flags.insert("cli-version")
                index += 1
                continue
            }
            if token.hasPrefix("-"), token != "-" {
                throw LauncherError(.usageError, "Unknown option \(token)", suggestion: "Run `lingxi help` for the supported options.")
            }
            input.positionals.append(token)
            index += 1
        }
        return input
    }
}
