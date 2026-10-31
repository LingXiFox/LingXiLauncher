import Foundation
import Darwin
import LauncherCore

public struct MacHost: PlatformHostProviding {
    public init() {}

    public var context: PlatformContext {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let processArch = Self.processArchitecture()
        return PlatformContext(
            os: .macOS,
            architecture: processArch,
            osVersion: osVersion,
            hostArchitecture: Self.hardwareArchitecture(processArch: processArch)
        )
    }

    public var pathListSeparator: String { ":" }

    public var defaultDataRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LingXiLauncher", isDirectory: true)
    }

    private static func hardwareArchitecture(processArch: PlatformContext.CPUArch) -> PlatformContext.CPUArch {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return .arm64 }
        return processArch
    }

    private static func processArchitecture() -> PlatformContext.CPUArch {
        var uts = utsname()
        guard uname(&uts) == 0 else { return .unknown }
        let machine = withUnsafeBytes(of: &uts.machine) { raw -> String in
            let pointer = raw.bindMemory(to: CChar.self)
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
        switch machine {
        case "arm64", "aarch64": return .arm64
        case "x86_64", "amd64": return .x86_64
        case "i386", "i686", "x86": return .x86
        default: return .unknown
        }
    }
}
