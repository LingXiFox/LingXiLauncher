import Foundation
import LauncherCore
#if canImport(WinSDK)
import WinSDK

/// Kernel-managed, cross-process lock backed by LockFileEx. The lock file is never deleted:
/// deleting it could let a second process lock a different inode while the first still runs.
public struct WindowsFileLocking: FileLocking {
    public init() {}

    public func acquireExclusive(at url: URL) throws -> any FileLockToken {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let token = try WindowsFileLockToken.openAndLock(url: url) {
                return token
            }
            if Date() >= deadline {
                throw LauncherError(.ioFailure, "Timed out waiting for instance lock at \(url.path)")
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
    }
}

private final class WindowsFileLockToken: FileLockToken, @unchecked Sendable {
    private var handle: HANDLE?
    private var overlapped = OVERLAPPED()

    private init(handle: HANDLE) { self.handle = handle }

    static func openAndLock(url: URL) throws -> WindowsFileLockToken? {
        let path = url.path
        let handle = path.withCString(encodedAs: UTF16.self) { pointer in
            CreateFileW(
                pointer,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw LauncherError(.ioFailure, "Cannot open instance lock at \(path)")
        }
        var token = WindowsFileLockToken(handle: handle)
        let locked = LockFileEx(
            handle,
            DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY),
            0,
            1,
            0,
            &token.overlapped
        )
        if !locked {
            CloseHandle(handle)
            token.handle = nil
            return nil
        }
        return token
    }

    func release() {
        guard let handle else { return }
        _ = UnlockFileEx(handle, 0, 1, 0, &overlapped)
        CloseHandle(handle)
        self.handle = nil
    }
}
#else
public struct WindowsFileLocking: FileLocking {
    public init() {}
    public func acquireExclusive(at url: URL) throws -> any FileLockToken {
        throw LauncherError(.ioFailure, "Windows file locking is unavailable")
    }
}
#endif
