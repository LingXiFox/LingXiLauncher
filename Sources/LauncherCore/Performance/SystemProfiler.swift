import Foundation

/// Portable facade over the injected platform profiler. No Metal/Darwin APIs live in Core.
public enum SystemProfiler {
    public static func hardware() -> PerformanceHardwareProfile {
        let profile = PlatformRuntime.system.hardware()
        return PerformanceHardwareProfile(
            modelIdentifier: profile.model,
            cpuModel: profile.cpu,
            architecture: profile.architecture,
            physicalCores: profile.physicalCores,
            logicalCores: profile.logicalCores,
            memoryBytes: profile.memoryBytes,
            operatingSystem: profile.operatingSystem,
            gpuModel: profile.gpu,
            gpuMemoryBytes: profile.gpuMemoryBytes
        )
    }

    public static func processIdentity(pid: Int32) -> ProcessIdentity? {
        PlatformRuntime.system.processIdentity(pid: pid)
    }

    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        PlatformRuntime.system.isAlive(identity)
    }

    public static func sampleProcess(_ identity: ProcessIdentity) -> ProcessResourceSample? {
        PlatformRuntime.system.sampleProcess(identity)
    }

    public static func elapsedSeconds(since identity: ProcessIdentity) -> Double {
        max(0, Date().timeIntervalSince1970 - Double(identity.startTimeSeconds) - Double(identity.startTimeMicroseconds) / 1_000_000)
    }
}
