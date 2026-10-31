import Foundation

/// Host facts used by Mojang rules and path generation. No conditional compilation in Core.
public protocol PlatformHostProviding: Sendable {
    var context: PlatformContext { get }
    var pathListSeparator: String { get }
    var defaultDataRoot: URL { get }
}

public struct GenericSystemProfile: Sendable, Equatable {
    public let model: String
    public let cpu: String
    public let architecture: String
    public let physicalCores: Int
    public let logicalCores: Int
    public let memoryBytes: UInt64
    public let operatingSystem: String
    public let gpu: String?
    public let gpuMemoryBytes: UInt64?

    public init(model: String, cpu: String, architecture: String, physicalCores: Int, logicalCores: Int, memoryBytes: UInt64, operatingSystem: String, gpu: String?, gpuMemoryBytes: UInt64?) {
        self.model = model
        self.cpu = cpu
        self.architecture = architecture
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.memoryBytes = memoryBytes
        self.operatingSystem = operatingSystem
        self.gpu = gpu
        self.gpuMemoryBytes = gpuMemoryBytes
    }
}

public protocol SystemProfiling: Sendable {
    func hardware() -> GenericSystemProfile
    func processIdentity(pid: Int32) -> ProcessIdentity?
    func isAlive(_ identity: ProcessIdentity) -> Bool
    func sampleProcess(_ identity: ProcessIdentity) -> ProcessResourceSample?
}

public protocol GraphicsProbing: Sendable {
    func current() -> GraphicsCapabilities
}

public struct PortableHost: PlatformHostProviding {
    public init() {}
    public var context: PlatformContext {
        let env = ProcessInfo.processInfo.environment
        let os: PlatformContext.OperatingSystem
        if env["OS"] == "Windows_NT" { os = .windows }
        else if FileManager.default.fileExists(atPath: "/System/Library/CoreServices/SystemVersion.plist") { os = .macOS }
        else { os = .linux }
        let info = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"
        let arch = Self.currentArchitecture()
        return PlatformContext(os: os, architecture: arch, osVersion: version, hostArchitecture: arch)
    }
    public var pathListSeparator: String {
        ProcessInfo.processInfo.environment["OS"] == "Windows_NT" ? ";" : ":"
    }
    public var defaultDataRoot: URL {
        if ProcessInfo.processInfo.environment["OS"] == "Windows_NT" {
            let base = ProcessInfo.processInfo.environment["APPDATA"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("LingXiLauncher", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LingXiLauncher", isDirectory: true)
    }
    public static func currentArchitecture() -> PlatformContext.CPUArch {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["PROCESSOR_ARCHITECTURE"]?.lowercased() {
            if raw.contains("arm64") || raw.contains("aarch64") { return .arm64 }
            if raw == "amd64" || raw == "x86_64" { return .x86_64 }
            if raw == "x86" || raw == "i386" { return .x86 }
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/uname") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/uname")
            p.arguments = ["-m"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                p.waitUntilExit()
                let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "arm64" || value == "aarch64" { return .arm64 }
                if value == "x86_64" { return .x86_64 }
            }
        }
        return .unknown
    }
}

public struct GenericSystemProfiler: SystemProfiling {
    public init() {}
    public func hardware() -> GenericSystemProfile {
        let info = ProcessInfo.processInfo
        return GenericSystemProfile(
            model: "Unknown",
            cpu: "Unknown",
            architecture: PortableHost.currentArchitecture().rawValue,
            physicalCores: max(1, info.activeProcessorCount),
            logicalCores: max(1, info.activeProcessorCount),
            memoryBytes: info.physicalMemory,
            operatingSystem: info.operatingSystemVersionString,
            gpu: nil,
            gpuMemoryBytes: nil
        )
    }
    public func processIdentity(pid: Int32) -> ProcessIdentity? { nil }
    public func isAlive(_ identity: ProcessIdentity) -> Bool { false }
    public func sampleProcess(_ identity: ProcessIdentity) -> ProcessResourceSample? { nil }
}

public struct GenericGraphicsProbe: GraphicsProbing {
    public init() {}
    public func current() -> GraphicsCapabilities {
        GraphicsCapabilities(openGLVersion: nil, renderer: nil, shadingLanguageVersion: nil, isAppleSilicon: false, probeError: "Graphics probing is not configured")
    }
}
