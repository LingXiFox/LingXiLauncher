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
    nonisolated(unsafe) private static var installedHost: (any PlatformHostProviding)?
    nonisolated(unsafe) private static var installedSystem: (any SystemProfiling)?
    nonisolated(unsafe) private static var installedGraphics: (any GraphicsProbing)?
    nonisolated(unsafe) private static var installedCredentials: (any RefreshTokenStoring)?
    nonisolated(unsafe) private static var installedArchive: (any ArchiveHandling)?

    public static func install(fileLock: any FileLocking) {
        lock.lock()
        installedFileLock = fileLock
        lock.unlock()
    }

    public static func install(host: any PlatformHostProviding, system: any SystemProfiling, graphics: any GraphicsProbing) {
        lock.lock()
        installedHost = host
        installedSystem = system
        installedGraphics = graphics
        lock.unlock()
    }

    public static var host: any PlatformHostProviding {
        lock.lock(); defer { lock.unlock() }
        return installedHost ?? PortableHost()
    }

    public static var system: any SystemProfiling {
        lock.lock(); defer { lock.unlock() }
        return installedSystem ?? GenericSystemProfiler()
    }

    public static func install(credentials: any RefreshTokenStoring) {
        lock.lock()
        installedCredentials = credentials
        lock.unlock()
    }

    public static func install(archive: any ArchiveHandling) {
        lock.lock()
        installedArchive = archive
        lock.unlock()
    }

    public static var archive: any ArchiveHandling {
        lock.lock(); defer { lock.unlock() }
        return installedArchive ?? UnsupportedArchiveHandler()
    }

    public static var credentials: any RefreshTokenStoring {
        lock.lock(); defer { lock.unlock() }
        return installedCredentials ?? InMemoryRefreshTokenStore()
    }

    public static var graphics: any GraphicsProbing {
        lock.lock(); defer { lock.unlock() }
        return installedGraphics ?? GenericGraphicsProbe()
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
