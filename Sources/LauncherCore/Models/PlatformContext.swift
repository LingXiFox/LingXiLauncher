import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The platform facts that Mojang metadata rules are evaluated against.
///
/// `osVersion` is required for `os.version` regex rules and `os.versionRange` bounds.
/// `features` are the launcher-controlled feature flags (demo mode, custom resolution,
/// quick play, ...). A feature that is absent is treated as **not enabled** — never as `true`.
public struct PlatformContext: Sendable, Hashable {
    public enum OperatingSystem: String, Sendable, Hashable, Codable {
        /// Mojang spells macOS as `osx`.
        case macOS = "osx"
        case linux
        case windows
    }

    public enum CPUArch: String, Sendable, Hashable, Codable {
        case arm64
        case x86_64
        /// 32-bit x86. Mojang rules historically refer to this as `x86`.
        case x86
        case unknown
    }

    public let os: OperatingSystem
    public let architecture: CPUArch
    /// Numeric dot-separated OS version, e.g. `14.4.1` on macOS.
    public let osVersion: String
    public let features: [String: Bool]

    public init(
        os: OperatingSystem,
        architecture: CPUArch,
        osVersion: String,
        features: [String: Bool] = [:]
    ) {
        self.os = os
        self.architecture = architecture
        self.osVersion = osVersion
        self.features = features
    }

    /// The architecture names Mojang metadata may use for this CPU.
    public var architectureAliases: [String] {
        switch architecture {
        case .arm64: return ["arm64", "aarch64"]
        case .x86_64: return ["x86_64", "amd64", "x86-64"]
        case .x86: return ["x86", "i386", "i686"]
        case .unknown: return []
        }
    }

    public func featureEnabled(_ name: String) -> Bool {
        features[name] ?? false
    }

    /// A context describing the machine this process runs on.
    ///
    /// Throws for operating systems LingXi Launcher does not support, rather than guessing rules.
    public static func current(features: [String: Bool] = [:]) throws -> PlatformContext {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(macOS)
        let os = OperatingSystem.macOS
        #elseif os(Linux)
        let os = OperatingSystem.linux
        #elseif os(Windows)
        let os = OperatingSystem.windows
        #else
        throw LauncherError(.unsupportedVersion, "Unsupported host operating system", suggestion: "LingXi Launcher targets macOS 14+ on Apple Silicon only.")
        #endif
        return PlatformContext(
            os: os,
            architecture: hostArchitecture(),
            osVersion: osVersion,
            features: features
        )
    }

    /// Reads the CPU architecture of the *current process* (not the machine), so a Rosetta
    /// translated launcher reports the architecture its JVM children would inherit.
    public static func hostArchitecture() -> CPUArch {
        #if canImport(Darwin)
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
        #else
        return .unknown
        #endif
    }
}
