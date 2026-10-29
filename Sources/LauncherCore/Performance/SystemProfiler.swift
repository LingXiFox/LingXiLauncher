import Foundation
#if canImport(Metal)
import Metal
#endif

#if canImport(Darwin)
import Darwin
#endif

public enum SystemProfiler {
    public static func hardware() -> PerformanceHardwareProfile {
        let process = ProcessInfo.processInfo
        let memory = process.physicalMemory
        let cpu = sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "Apple Silicon"
        let model = sysctlString("hw.model") ?? sysctlString("machdep.cpu.brand_string") ?? "Mac"
        let physical = Int(sysctlInt("hw.physicalcpu") ?? Int64(process.activeProcessorCount))
        let logical = process.activeProcessorCount
        let os = "\(process.operatingSystemVersionString)"
        let gpu = gpuInfo()
        return PerformanceHardwareProfile(
            modelIdentifier: model,
            cpuModel: cpu,
            architecture: architectureName(),
            physicalCores: max(1, physical),
            logicalCores: max(1, logical),
            memoryBytes: memory,
            operatingSystem: os,
            gpuModel: gpu?.model,
            gpuMemoryBytes: gpu?.memoryBytes
        )
    }

    public static func processIdentity(pid: Int32) -> ProcessIdentity? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let value = info.kp_proc.p_starttime
        return ProcessIdentity(
            processIdentifier: pid,
            startTimeSeconds: Int64(value.tv_sec),
            startTimeMicroseconds: Int32(value.tv_usec)
        )
        #else
        return nil
        #endif
    }

    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let current = processIdentity(pid: identity.processIdentifier) else { return false }
        return current == identity
    }

    public static func sampleProcess(_ identity: ProcessIdentity) -> ProcessResourceSample? {
        guard isAlive(identity) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(identity.processIdentifier), "-o", "%cpu=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let fields = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard fields.count >= 2,
              let cpu = Double(fields[0]),
              let rssKiB = UInt64(fields[1]) else { return nil }
        let started = Date(timeIntervalSince1970: Double(identity.startTimeSeconds))
        return ProcessResourceSample(
            offsetSeconds: max(0, Date().timeIntervalSince(started)),
            cpuPercent: max(0, cpu),
            residentBytes: rssKiB * 1024
        )
    }

    public static func elapsedSeconds(since identity: ProcessIdentity) -> Double {
        max(0, Date().timeIntervalSince1970 - Double(identity.startTimeSeconds) - Double(identity.startTimeMicroseconds) / 1_000_000)
    }

    private static func architectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func gpuInfo() -> (model: String?, memoryBytes: UInt64?)? {
        #if canImport(Metal)
        // Metal's device query is in-process and cannot hang the SwiftUI main actor on a
        // subprocess. Avoid `system_profiler` here: it can take seconds and caused a UI graph
        // re-entrancy crash when called from a StateObject initializer.
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let memory = device.recommendedMaxWorkingSetSize > 0 ? device.recommendedMaxWorkingSetSize : nil
        return (device.name, memory)
        #else
        return nil
        #endif
    }

    private static func parseMemory(_ raw: String) -> UInt64? {
        let lower = raw.lowercased()
        let number = Double(lower.split(whereSeparator: { !$0.isNumber && $0 != "." }).first ?? "0") ?? 0
        if lower.contains("gb") { return UInt64(number * 1_073_741_824) }
        if lower.contains("mb") { return UInt64(number * 1_048_576) }
        return nil
    }
}
