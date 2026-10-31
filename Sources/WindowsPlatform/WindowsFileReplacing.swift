import Foundation
import LauncherCore
#if canImport(WinSDK)
import WinSDK

/// Uses MoveFileExW with REPLACE_EXISTING and WRITE_THROUGH. Both paths must be on the same
/// volume; cross-volume moves fail rather than silently degrading into copy + delete.
public struct WindowsFileReplacing: FileReplacing {
    public init() {}
    public func replaceItem(at destination: URL, with item: URL) throws {
        let ok = item.path.withCString(encodedAs: UTF16.self) { source in
            destination.path.withCString(encodedAs: UTF16.self) { target in
                MoveFileExW(
                    source,
                    target,
                    DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH)
                )
            }
        }
        guard ok else {
            throw LauncherError(.ioFailure, "Atomic replacement failed for \(destination.path)")
        }
    }
}
#else
public struct WindowsFileReplacing: FileReplacing {
    public init() {}
    public func replaceItem(at destination: URL, with item: URL) throws {
        throw LauncherError(.ioFailure, "Atomic replacement is unavailable")
    }
}
#endif
