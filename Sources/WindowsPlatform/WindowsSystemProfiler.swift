import Foundation
import LauncherCore

public struct WindowsSystemProfiler: SystemProfiling {
    public init() {}

    public func hardware() -> GenericSystemProfile {
        let process = ProcessInfo.processInfo
        return GenericSystemProfile(
            model: "PC",
            cpu: process.environment["PROCESSOR_IDENTIFIER"] ?? "x86_64",
            architecture: "x86_64",
            physicalCores: max(1, process.activeProcessorCount),
            logicalCores: max(1, process.activeProcessorCount),
            memoryBytes: process.physicalMemory,
            operatingSystem: process.operatingSystemVersionString,
            gpu: nil,
            gpuMemoryBytes: nil
        )
    }

    public func processIdentity(pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        return ProcessIdentity(processIdentifier: pid, startTimeSeconds: 0, startTimeMicroseconds: 0)
    }

    public func isAlive(_ identity: ProcessIdentity) -> Bool {
        PlatformRuntime.process.isRunning(pid: identity.processIdentifier)
    }

    public func sampleProcess(_ identity: ProcessIdentity) -> ProcessResourceSample? {
        ProcessResourceSample(offsetSeconds: 0, cpuPercent: 0, residentBytes: 0)
    }
}
