import Foundation
import LauncherCore

public struct WindowsFileLocking: FileLocking {
    public init() {}

    public func acquire(at url: URL, timeout: TimeInterval) throws -> any FileLockToken {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                return WindowsFileLockToken(url: url)
            } catch CocoaError.fileWriteFileExists {
                if Date() >= deadline {
                    throw LauncherError(.ioFailure, "Timed out waiting for instance lock at \(url.path)")
                }
                Thread.sleep(forTimeInterval: 0.05)
            } catch {
                throw LauncherError(.ioFailure, "Cannot create instance lock: \(error.localizedDescription)")
            }
        } while true
    }
}

private struct WindowsFileLockToken: FileLockToken {
    let url: URL
    func unlock() {
        try? FileManager.default.removeItem(at: url)
    }
}
