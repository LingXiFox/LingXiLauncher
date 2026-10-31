import Foundation
import LauncherCore
#if canImport(MacPlatform)
import MacPlatform
MacPlatform.install()
#elseif canImport(WindowsPlatform)
import WindowsPlatform
WindowsPlatform.install()
#endif

// Thin shell: parse argv, call LauncherCore, map the result to an exit code.
let status = await CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
