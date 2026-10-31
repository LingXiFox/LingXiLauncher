import Foundation

/// A held cross-process lock. Releasing must be idempotent.
public protocol FileLockToken: AnyObject, Sendable {
    func release()
}

/// OS-specific advisory locking. Core only depends on this protocol.
public protocol FileLocking: Sendable {
    func acquireExclusive(at url: URL) throws -> any FileLockToken
}

/// Process-wide platform registry. The macOS app and CLI install MacPlatform services at startup;
/// tests and unsupported hosts get a Foundation-only fallback.
public enum PlatformRuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installedFileLock: (any FileLocking)?

    public static func install(fileLock: any FileLocking) {
        lock.lock()
        installedFileLock = fileLock
        lock.unlock()
    }

    public static var fileLock: any FileLocking {
        lock.lock()
        defer { lock.unlock() }
        return installedFileLock ?? FoundationFileLocking()
    }
}

/// Portable fallback used by unit tests. It is not a replacement for the Mac/Windows OS lock in
/// production: an atomically created directory is still visible to other processes.
public struct FoundationFileLocking: FileLocking {
    public init() {}

    public func acquireExclusive(at url: URL) throws -> any FileLockToken {
        let directory = url.appendingPathExtension("lockdir")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            throw LauncherError(.launchFailed, "Another launcher process holds \(url.lastPathComponent)")
        }
        return Token(directory: directory)
    }

    private final class Token: FileLockToken, @unchecked Sendable {
        let directory: URL
        init(directory: URL) { self.directory = directory }
        func release() { try? FileManager.default.removeItem(at: directory) }
    }
}
