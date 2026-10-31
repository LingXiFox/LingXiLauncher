import Foundation
import LauncherCore

public struct WindowsFileLocking: FileLocking {
    public init() {}

    public func acquireExclusive(at url: URL) throws -> any FileLockToken {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                return WindowsFileLockToken(url: url)
            } catch {
                if Date() >= deadline {
                    throw LauncherError(.ioFailure, "Timed out waiting for instance lock at \(url.path)")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } while true
    }
}

private final class WindowsFileLockToken: FileLockToken, @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
