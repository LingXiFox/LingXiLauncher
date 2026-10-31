import Foundation
import LauncherCore

public struct WindowsHost: PlatformHostProviding {
    public init() {}

    public var context: PlatformContext {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return PlatformContext(
            os: .windows,
            architecture: .x86_64,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            hostArchitecture: .x86_64
        )
    }

    public var pathListSeparator: String { ";" }

    public var defaultDataRoot: URL {
        if let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty {
            return URL(fileURLWithPath: appData, isDirectory: true)
                .appendingPathComponent("LingXiLauncher", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("AppData/Roaming/LingXiLauncher", isDirectory: true)
    }
}
