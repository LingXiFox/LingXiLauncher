import Foundation
import LauncherCore

public enum WindowsPlatform {
    public static func install() {
        PlatformRuntime.install(fileLock: WindowsFileLocking())
        PlatformRuntime.install(host: WindowsHost(), system: WindowsSystemProfiler(), graphics: WindowsGraphicsProbe())
        PlatformRuntime.install(credentials: InMemoryRefreshTokenStore())
        PlatformRuntime.install(archive: WindowsArchiveHandler())
        PlatformRuntime.install(process: WindowsProcessInspector())
    }
}
