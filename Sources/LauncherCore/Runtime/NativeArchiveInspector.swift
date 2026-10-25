import Foundation

/// Reads CPU architectures out of Mach-O binaries and native JARs.
///
/// Used to verify that a native archive actually contains code for the selected JVM. The
/// classifier name is only a hint from Mojang metadata; the Mach-O header is ground truth.
public enum MachOInspector {
    /// Returns every architecture present in a thin or fat Mach-O file.
    public static func architectures(in data: Data) -> Set<PlatformContext.CPUArch> {
        guard data.count >= 8 else { return [] }
        let magic = beUInt32(data, 0)

        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            return fatArchitectures(in: data, is64: magic == 0xCAFE_BABF)
        case 0xFEED_FACF: // big-endian 64-bit
            return Set([map(cpuType: beUInt32(data, 4))].compactMap { $0 })
        case 0xFEED_FACE: // big-endian 32-bit
            return Set([map(cpuType: beUInt32(data, 4))].compactMap { $0 })
        case 0xCFFA_EDFE: // little-endian 64-bit
            return Set([map(cpuType: leUInt32(data, 4))].compactMap { $0 })
        case 0xCEFA_EDFE: // little-endian 32-bit
            return Set([map(cpuType: leUInt32(data, 4))].compactMap { $0 })
        default:
            return []
        }
    }

    static func map(cpuType: UInt32) -> PlatformContext.CPUArch? {
        switch cpuType {
        case 0x0100_000C, 0x0200_000C: return .arm64
        case 0x0100_0007: return .x86_64
        case 0x0000_0007: return .x86
        case 0x0000_000C: return .arm64
        default: return nil
        }
    }

    private static func fatArchitectures(in data: Data, is64: Bool) -> Set<PlatformContext.CPUArch> {
        guard data.count >= 8 else { return [] }
        let count = Int(beUInt32(data, 4))
        guard count > 0, count <= 32 else { return [] }
        let entrySize = is64 ? 32 : 20
        var result: Set<PlatformContext.CPUArch> = []
        for index in 0..<count {
            let offset = 8 + index * entrySize
            guard offset + 4 <= data.count else { break }
            if let architecture = map(cpuType: beUInt32(data, offset)) {
                result.insert(architecture)
            }
        }
        return result
    }

    private static func beUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func leUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

/// Inspects a native JAR (stored/deflate ZIP) and reports the architectures of its Mach-O
/// payloads. Returns an empty set for archives without recognisable Mach-O files.
public enum NativeArchiveInspector {
    public static func architectures(
        ofArchive url: URL,
        limits: SafeZipExtractor.Limits = SafeZipExtractor.Limits()
    ) throws -> Set<PlatformContext.CPUArch> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read native archive \(url.path): \(error.localizedDescription)")
        }
        let entries = try SafeZipExtractor.readEntries(data, limits: limits)
        var result: Set<PlatformContext.CPUArch> = []
        for entry in entries where !entry.isDirectory {
            guard isNativeBinary(entry.name) else { continue }
            result.formUnion(MachOInspector.architectures(in: entry.data))
        }
        return result
    }

    public static func isNativeBinary(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".dylib") || lowered.hasSuffix(".jnilib") || lowered.hasSuffix(".so")
    }
}

/// Compares native archives against the selected JVM architecture.
public enum NativeCompatibility {
    /// Metadata classifier hints can be absent (plain `natives-macos`), so the archive contents
    /// are inspected when the file is available. Returns one error per incompatible archive.
    public static func diagnostics(
        for natives: [ResolvedNative],
        jvmArchitecture: PlatformContext.CPUArch
    ) -> [LaunchDiagnostic] {
        var diagnostics: [LaunchDiagnostic] = []
        for native in natives {
            guard FileManager.default.fileExists(atPath: native.file.path.path) else { continue }
            guard let architectures = try? NativeArchiveInspector.architectures(ofArchive: native.file.path),
                  !architectures.isEmpty else { continue }
            if !architectures.contains(jvmArchitecture) {
                let found = architectures.map(\.rawValue).sorted().joined(separator: ", ")
                diagnostics.append(.error(
                    .javaArchitectureMismatch,
                    "Native archive '\(native.classifier)' contains \(found) libraries but the selected JVM is \(jvmArchitecture.rawValue)",
                    suggestion: "Select a JVM matching the archive architecture or install a version that ships \(jvmArchitecture.rawValue) natives."
                ))
            }
        }
        return diagnostics
    }
}
