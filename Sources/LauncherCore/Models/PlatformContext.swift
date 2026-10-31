import Foundation

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
    /// The architecture Mojang rules are evaluated for. This is the **JVM** architecture, not
    /// necessarily the launcher process or the hardware: an x86_64 Java under Rosetta on an
    /// Apple Silicon Mac must select x86_64 natives.
    public let architecture: CPUArch
    /// The real hardware architecture, independent of Rosetta translation of this process.
    public let hostArchitecture: CPUArch
    /// Numeric dot-separated OS version, e.g. `14.4.1` on macOS.
    public let osVersion: String
    public let features: [String: Bool]

    public init(
        os: OperatingSystem,
        architecture: CPUArch,
        osVersion: String,
        features: [String: Bool] = [:],
        hostArchitecture: CPUArch? = nil
    ) {
        self.os = os
        self.architecture = architecture
        self.osVersion = osVersion
        self.features = features
        self.hostArchitecture = hostArchitecture ?? architecture
    }

    /// True when the selected JVM is x86_64 on Apple Silicon hardware (Rosetta 2 translation).
    public var isTranslated: Bool {
        hostArchitecture == .arm64 && architecture == .x86_64
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
        let host = PlatformRuntime.host.context
        return PlatformContext(
            os: host.os,
            architecture: host.architecture,
            osVersion: host.osVersion,
            features: features,
            hostArchitecture: host.hostArchitecture
        )
    }

    /// Builds the rule-evaluation context for a concrete JVM.
    ///
    /// The OS and its version come from the host; the architecture comes from `runtime`, which
    /// was measured by actually executing that Java. This is the context that must be passed to
    /// `DependencyResolver`, `RuleEvaluator` and `LaunchPlanBuilder` so natives are chosen for
    /// the JVM that will load them.
    public static func forJVM(_ runtime: JavaRuntime, features: [String: Bool] = [:]) throws -> PlatformContext {
        let host = try current(features: features)
        return PlatformContext(
            os: host.os,
            architecture: runtime.architecture,
            osVersion: host.osVersion,
            features: features,
            hostArchitecture: host.hostArchitecture
        )
    }

    /// Hardware architecture of the machine, even when this process runs translated by Rosetta.
    /// `hw.optional.arm64` reports the physical CPU; `uname` reports the *process* ABI.
    public static func hardwareArchitecture() -> CPUArch {
        PlatformRuntime.host.context.hostArchitecture
    }

    /// Reads the CPU architecture the current process would hand to child JVMs.
    public static func hostArchitecture() -> CPUArch {
        PlatformRuntime.host.context.architecture
    }

}
