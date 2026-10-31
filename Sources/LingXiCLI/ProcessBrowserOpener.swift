import Foundation
import LauncherCore

/// Opens the system browser without a shell. CLI-safe (no AppKit main-thread requirements).
struct ProcessBrowserOpener: BrowserOpening {
    func open(_ url: URL) throws {
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        #else
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", "start", "", url.absoluteString]
        #endif
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LauncherError(
                .unauthorized,
                "Could not open the system browser: \(error.localizedDescription)",
                suggestion: "Copy the printed authorization URL into a browser manually."
            )
        }
        guard process.terminationStatus == 0 else {
            throw LauncherError(
                .unauthorized,
                "The system browser refused to open the Microsoft sign-in page (exit \(process.terminationStatus))"
            )
        }
    }
}
