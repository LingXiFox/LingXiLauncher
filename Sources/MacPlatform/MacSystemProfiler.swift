import Foundation
import Darwin
import Metal
import LauncherCore

public struct MacSystemProfiler: SystemProfiling {
    public init() {}

    public func hardware() -> GenericSystemProfile {
        let process = ProcessInfo.processInfo
        let memory = process.physicalMemory
        let cpu = sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "Apple Silicon"
        let model = sysctlString("hw.model") ?? "Mac"
        let physical = Int(sysctlInt("hw.physicalcpu") ?? Int64(process.activeProcessorCount))
        let logical = process.activeProcessorCount
        let gpu = gpuInfo()
        return GenericSystemProfile(
            model: model,
            cpu: cpu,
            architecture: PlatformContext.hostArchitecture().rawValue,
            physicalCores: max(1, physical),
            logicalCores: max(1, logical),
            memoryBytes: memory,
            operatingSystem: process.operatingSystemVersionString,
            gpu: gpu?.model,
            gpuMemoryBytes: gpu?.memoryBytes
        )
    }

    public func processIdentity(pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let value = info.kp_proc.p_starttime
        return ProcessIdentity(processIdentifier: pid, startTimeSeconds: Int64(value.tv_sec), startTimeMicroseconds: Int32(value.tv_usec))
    }

    public func isAlive(_ identity: ProcessIdentity) -> Bool {
        processIdentity(pid: identity.processIdentifier) == identity
    }

    public func sampleProcess(_ identity: ProcessIdentity) -> ProcessResourceSample? {
        guard isAlive(identity) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(identity.processIdentifier), "-o", "%cpu=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        let fields = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard fields.count >= 2, let cpu = Double(fields[0]), let rssKiB = UInt64(fields[1]) else { return nil }
        let started = Date(timeIntervalSince1970: Double(identity.startTimeSeconds))
        return ProcessResourceSample(
            offsetSeconds: max(0, Date().timeIntervalSince(started)),
            cpuPercent: max(0, cpu),
            residentBytes: rssKiB * 1024
        )
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private func gpuInfo() -> (model: String?, memoryBytes: UInt64?)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let memory = device.recommendedMaxWorkingSetSize > 0 ? device.recommendedMaxWorkingSetSize : nil
        return (device.name, memory)
    }
}
