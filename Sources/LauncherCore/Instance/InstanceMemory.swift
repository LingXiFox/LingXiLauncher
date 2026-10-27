import Foundation

/// Launcher-owned JVM heap policy.
///
/// `InstanceManifest.memoryMiB == nil` means **automatic**, not "no -Xmx": every launch gets a
/// concrete heap limit derived from the host's physical memory. A manual value is respected
/// verbatim after validation by `InstanceRepository`.
public enum InstanceMemory {
    public static let manualRange = 256...65_536
    public static let automaticFloorMiB = 1_024
    public static let automaticCeilingMiB = 8_192

    /// 1 GiB of RAM → 256 MiB of heap, capped at 8 GiB. Examples:
    /// 8 GiB host → 2 GiB, 16 GiB → 4 GiB, 32 GiB → 8 GiB, 64 GiB → 8 GiB.
    public static func automaticMiB(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        guard physicalMemoryBytes > 0 else { return 2_048 }
        let gib = Double(physicalMemoryBytes) / 1_073_741_824.0
        let proposed = Int(gib * 256)
        return min(automaticCeilingMiB, max(automaticFloorMiB, proposed))
    }

    public static func resolvedMiB(
        configured: Int?,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        configured ?? automaticMiB(physicalMemoryBytes: physicalMemoryBytes)
    }

    public static func jvmArguments(
        configured: Int?,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> [String] {
        ["-Xmx\(resolvedMiB(configured: configured, physicalMemoryBytes: physicalMemoryBytes))M"]
    }

    public static func isManual(_ configured: Int?) -> Bool {
        configured != nil
    }
}
