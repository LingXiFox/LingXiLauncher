import Foundation
import Darwin
import LauncherCore

/// Darwin flock-backed lock. The descriptor stays open for the lifetime of the token.
public struct MacFileLocking: FileLocking {
    public init() {}

    public func acquireExclusive(at url: URL) throws -> any FileLockToken {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LauncherError(.ioFailure, "Cannot open lock \(url.path)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LauncherError(.launchFailed, "Another launcher process holds \(url.lastPathComponent)")
        }
        return Token(descriptor: descriptor)
    }

    private final class Token: FileLockToken, @unchecked Sendable {
        private var descriptor: Int32
        init(descriptor: Int32) { self.descriptor = descriptor }
        func release() {
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            descriptor = -1
        }
        deinit { release() }
    }
}
