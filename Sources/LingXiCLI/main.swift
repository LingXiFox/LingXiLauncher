import Foundation
import LauncherCore

// Thin shell: parse argv, call LauncherCore, map the result to an exit code.
let status = await CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
