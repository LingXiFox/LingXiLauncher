import Compression
import Foundation
import LauncherCore

/// Minimal, defensive ZIP reader used to extract Minecraft native JARs.
///
/// Why not `unzip`/`ditto`? Extraction of externally supplied archives is a security boundary:
/// a subprocess would happily create the symlink entries and `../` paths that the spec requires
/// us to reject. This reader:
/// - validates every entry name through `PathSafety` (no `..`, absolute paths, backslashes),
/// - refuses archives that contain symlink entries at all (native JARs never need them),
/// - bounds per-entry and total uncompressed sizes (zip-bomb guard),
/// - only supports the stored/deflate methods actually used by JARs (ZIP64 is rejected).
///
/// Integrity of the archive itself is established before extraction: the installer verifies the
/// JAR's SHA-1 from Mojang metadata, so CRC-32 is not re-checked here.
public struct MacArchiveHandler: ArchiveHandling {
    public init() {}
    /// Extracts `archive` into `directory`, skipping names that match `excludedPrefixes`.
    /// Returns the entries that were written.
    @discardableResult
    public func extract(
        archive: URL,
        into directory: URL,
        excluding excludedPrefixes: [String],
        limits: ArchiveLimits
    ) throws -> [ArchiveExtractedEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: archive)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read native archive \(archive.path): \(error.localizedDescription)")
        }
        let entries = try readEntries(data, limits: limits)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LauncherError(.ioFailure, "Cannot create natives directory \(directory.path): \(error.localizedDescription)")
        }

        var written: [ArchiveExtractedEntry] = []
        for entry in entries {
            if entry.isDirectory { continue }
            if excludedPrefixes.contains(where: { !$0.isEmpty && entry.name.hasPrefix($0) }) { continue }

            let target = try PathSafety.safeJoin(base: directory, relativePath: entry.name)
            if !PathSafety.isContainedResolvingSymlinks(target.deletingLastPathComponent(), inBase: directory) {
                throw LauncherError(.pathEscapesRoot, "Native archive entry '\(entry.name)' escapes \(directory.path) via a symlink")
            }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try entry.data.write(to: target, options: [.atomic])
            } catch {
                throw LauncherError(.ioFailure, "Cannot extract \(entry.name): \(error.localizedDescription)")
            }
            if !PathSafety.isContainedResolvingSymlinks(target, inBase: directory) {
                throw LauncherError(.pathEscapesRoot, "Native archive entry '\(entry.name)' resolved outside \(directory.path)")
            }
            written.append(ArchiveExtractedEntry(name: entry.name, bytes: entry.data.count))
        }
        return written
    }

    // MARK: - ZIP parsing

    public func readEntries(_ data: Data, limits: ArchiveLimits) throws -> [ArchiveEntry] {
        let eocdOffset = try findEndOfCentralDirectory(in: data)
        let totalEntries = try u16(data, eocdOffset + 10)
        let directorySize = try u32(data, eocdOffset + 12)
        let directoryOffset = try u32(data, eocdOffset + 16)

        guard totalEntries != 0xFFFF, directoryOffset != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else {
            throw LauncherError(.unsupportedVersion, "Native archive uses ZIP64, which is not supported")
        }
        guard totalEntries <= limits.maxEntries else {
            throw LauncherError(.invalidMetadata, "Native archive declares \(totalEntries) entries (limit \(limits.maxEntries))")
        }
        guard directoryOffset >= 0, directorySize >= 0,
              directoryOffset + directorySize <= data.count else {
            throw LauncherError(.invalidMetadata, "Native archive central directory is out of bounds")
        }

        var entries: [ArchiveEntry] = []
        var offset = directoryOffset
        var totalUncompressed = 0

        for _ in 0..<totalEntries {
            guard try u32(data, offset) == 0x0201_4B50 else {
                throw LauncherError(.invalidMetadata, "Native archive central directory entry is corrupt")
            }
            let versionMadeBy = try u16(data, offset + 4)
            let method = try u16(data, offset + 10)
            let compressedSize = try u32(data, offset + 20)
            let uncompressedSize = try u32(data, offset + 24)
            let nameLength = try u16(data, offset + 28)
            let extraLength = try u16(data, offset + 30)
            let commentLength = try u16(data, offset + 32)
            let externalAttributes = try u32(data, offset + 38)
            let localHeaderOffset = try u32(data, offset + 42)

            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF, localHeaderOffset != 0xFFFF_FFFF else {
                throw LauncherError(.unsupportedVersion, "Native archive uses ZIP64, which is not supported")
            }
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else {
                throw LauncherError(.invalidMetadata, "Native archive entry name is out of bounds")
            }
            let rawName = data.subdata(in: nameStart..<(nameStart + nameLength))
            guard let name = String(data: rawName, encoding: .utf8) ?? String(data: rawName, encoding: .isoLatin1) else {
                throw LauncherError(.invalidMetadata, "Native archive contains an undecodable entry name")
            }
            try PathSafety.validatedArchiveEntry(name)

            // Unix mode is only meaningful when the archive was produced on Unix (high byte 3).
            let unixMode = (versionMadeBy >> 8) == 3 ? Int(externalAttributes >> 16) : 0
            let fileType = unixMode & 0xF000
            let isSymlink = fileType == 0xA000
            let isDirectory = name.hasSuffix("/") || fileType == 0x4000
            if isSymlink {
                throw LauncherError(
                    .pathEscapesRoot,
                    "Native archive contains a symlink entry '\(name)'; refusing to extract it"
                )
            }

            guard uncompressedSize <= limits.maxEntrySize else {
                throw LauncherError(.invalidMetadata, "Native archive entry '\(name)' is \(uncompressedSize) bytes (limit \(limits.maxEntrySize))")
            }
            totalUncompressed += uncompressedSize
            guard totalUncompressed <= limits.maxTotalSize else {
                throw LauncherError(.invalidMetadata, "Native archive expands beyond \(limits.maxTotalSize) bytes")
            }

            let payload: Data
            if isDirectory {
                payload = Data()
            } else {
                payload = try readPayload(
                    data,
                    localHeaderOffset: localHeaderOffset,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
            }

            entries.append(ArchiveEntry(name: name, isDirectory: isDirectory, isSymlink: false, data: payload))
            offset = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    private func readPayload(
        _ data: Data,
        localHeaderOffset: Int,
        method: Int,
        compressedSize: Int,
        uncompressedSize: Int
    ) throws -> Data {
        guard localHeaderOffset >= 0, localHeaderOffset + 30 <= data.count else {
            throw LauncherError(.invalidMetadata, "Native archive local header is out of bounds")
        }
        guard try u32(data, localHeaderOffset) == 0x0403_4B50 else {
            throw LauncherError(.invalidMetadata, "Native archive local header is corrupt")
        }
        let nameLength = try u16(data, localHeaderOffset + 26)
        let extraLength = try u16(data, localHeaderOffset + 28)
        let payloadStart = localHeaderOffset + 30 + nameLength + extraLength
        guard payloadStart >= 0, compressedSize >= 0, payloadStart + compressedSize <= data.count else {
            throw LauncherError(.invalidMetadata, "Native archive entry payload is out of bounds")
        }
        let compressed = data.subdata(in: payloadStart..<(payloadStart + compressedSize))

        switch method {
        case 0:
            guard compressed.count == uncompressedSize else {
                throw LauncherError(.invalidMetadata, "Native archive stored entry has inconsistent sizes")
            }
            return compressed
        case 8:
            if uncompressedSize == 0 { return Data() }
            var output = Data(count: uncompressedSize)
            let decoded = output.withUnsafeMutableBytes { destination -> Int in
                compressed.withUnsafeBytes { source -> Int in
                    guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                          let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_decode_buffer(
                        destinationBase,
                        uncompressedSize,
                        sourceBase,
                        compressed.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decoded == uncompressedSize else {
                throw LauncherError(.invalidMetadata, "Native archive deflate stream is corrupt")
            }
            return output
        default:
            throw LauncherError(.unsupportedVersion, "Native archive uses unsupported compression method \(method)")
        }
    }

    private func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let minimum = 22
        guard data.count >= minimum else {
            throw LauncherError(.invalidMetadata, "Native archive is too small to be a ZIP file")
        }
        let searchStart = max(0, data.count - minimum - 0xFFFF)
        var offset = data.count - minimum
        while offset >= searchStart {
            if (try? u32(data, offset)) == 0x0605_4B50 {
                let commentLength = (try? u16(data, offset + 20)) ?? 0
                if offset + minimum + commentLength == data.count {
                    return offset
                }
            }
            offset -= 1
        }
        throw LauncherError(.invalidMetadata, "Native archive has no ZIP end-of-central-directory record")
    }

    // MARK: - Bounds-checked little-endian reads

    private func u16(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= data.count else {
            throw LauncherError(.invalidMetadata, "Native archive is truncated")
        }
        return Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private func u32(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= data.count else {
            throw LauncherError(.invalidMetadata, "Native archive is truncated")
        }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return Int(value)
    }
}
