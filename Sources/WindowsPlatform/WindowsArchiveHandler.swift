import Foundation
import LauncherCore

/// Windows ZIP facade. Entry metadata is parsed in Swift so traversal and collision checks run
/// before bsdtar touches the filesystem; the actual Stored/Deflate extraction uses the signed
/// Windows tar component. The post-extraction scan rejects links and size overruns.
public struct WindowsArchiveHandler: ArchiveHandling {
    public init() {}

    public func readEntries(_ data: Data, limits: ArchiveLimits) throws -> [ArchiveEntry] {
        let verified = try validateEntries(data, limits: limits)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-read-\(UUID().uuidString)", isDirectory: true)
        let zip = temp.appendingPathComponent("archive.zip")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: zip, options: .atomic)
        let output = temp.appendingPathComponent("files", isDirectory: true)
        try runTar(archive: zip, into: output)
        try validateExtractedTree(output, limits: limits)
        return try verified.map { entry in
            let contents: Data
            if entry.isDirectory {
                contents = Data()
            } else {
                contents = try Data(contentsOf: output.appendingPathComponent(entry.name))
            }
            return ArchiveEntry(
                name: entry.name,
                isDirectory: entry.isDirectory,
                isSymlink: entry.isSymlink,
                data: contents
            )
        }
    }

    private func validateEntries(_ data: Data, limits: ArchiveLimits) throws -> [ZIPCentralEntry] {
        let entries = try ZIPCentralDirectory.parse(data)
        guard entries.count <= limits.maxEntries else {
            throw LauncherError(.ioFailure, "Archive has too many entries")
        }
        var total = 0
        var seen = Set<String>()
        for entry in entries {
            try validate(name: entry.name)
            guard !entry.isSymlink else {
                throw LauncherError(.pathEscapesRoot, "Archive contains a symbolic link")
            }
            let key = entry.name.lowercased()
            guard seen.insert(key).inserted else {
                throw LauncherError(.pathEscapesRoot, "Archive contains case-colliding paths")
            }
            guard entry.uncompressedSize <= limits.maxEntrySize else {
                throw LauncherError(.ioFailure, "Archive entry exceeds size limit: \(entry.name)")
            }
            total += entry.uncompressedSize
            guard total <= limits.maxTotalSize else {
                throw LauncherError(.ioFailure, "Archive exceeds total size limit")
            }
        }
        return entries
    }

    private func runTar(archive: URL, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\tar.exe")
        process.arguments = ["-xf", archive.path, "-C", directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw LauncherError(.ioFailure, "Windows archive extraction failed: \(message)")
        }
    }

    public func extract(
        archive: URL,
        into directory: URL,
        excluding excludedPrefixes: [String],
        limits: ArchiveLimits
    ) throws -> [ArchiveExtractedEntry] {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try validateEntries(data, limits: limits)
        try runTar(archive: archive, into: directory)
        do {
            let extracted = try validateExtractedTree(directory, limits: limits)
            for prefix in excludedPrefixes {
                let target = directory.appendingPathComponent(prefix)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
            }
            return extracted.filter { item in !excludedPrefixes.contains { item.name.hasPrefix($0) } }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func validateExtractedTree(_ directory: URL, limits: ArchiveLimits) throws -> [ArchiveExtractedEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            throw LauncherError(.ioFailure, "Cannot enumerate extracted archive")
        }
        var result: [ArchiveExtractedEntry] = []
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw LauncherError(.pathEscapesRoot, "Archive contains a symbolic link")
            }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            try validate(name: relative)
            if values.isDirectory == true { continue }
            let size = values.fileSize ?? 0
            guard size <= limits.maxEntrySize else {
                throw LauncherError(.ioFailure, "Extracted entry exceeds size limit")
            }
            total += size
            guard total <= limits.maxTotalSize else {
                throw LauncherError(.ioFailure, "Extracted archive exceeds total size limit")
            }
            result.append(ArchiveExtractedEntry(name: relative, bytes: size))
        }
        return result
    }

    private func validate(name: String) throws {
        guard !name.isEmpty, !name.contains("\0"), !name.contains("\\") else {
            throw LauncherError(.pathEscapesRoot, "Invalid archive path")
        }
        guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains(":") else {
            throw LauncherError(.pathEscapesRoot, "Absolute or drive-qualified archive path")
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw LauncherError(.pathEscapesRoot, "Archive path escapes the extraction root")
            }
            guard !component.hasSuffix(" "), !component.hasSuffix(".") else {
                throw LauncherError(.pathEscapesRoot, "Windows reserved path component")
            }
            let base = component.split(separator: ".").first.map(String.init)?.uppercased() ?? ""
            let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
            guard !reserved.contains(base) else {
                throw LauncherError(.pathEscapesRoot, "Windows reserved file name")
            }
        }
    }
}

private struct ZIPCentralEntry {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let uncompressedSize: Int
}

private enum ZIPCentralDirectory {
    static func parse(_ data: Data) throws -> [ZIPCentralEntry] {
        guard let eocd = findEOCD(data) else {
            throw LauncherError(.ioFailure, "Not a valid ZIP archive")
        }
        let count = Int(readU16(data, eocd + 10))
        let offset = Int(readU32(data, eocd + 16))
        guard count >= 0, offset >= 0, offset < data.count else {
            throw LauncherError(.ioFailure, "Corrupt ZIP central directory")
        }
        var cursor = offset
        var entries: [ZIPCentralEntry] = []
        for _ in 0..<count {
            guard cursor + 46 <= data.count, readU32(data, cursor) == 0x0201_4b50 else {
                throw LauncherError(.ioFailure, "Corrupt ZIP central directory entry")
            }
            let flags = readU16(data, cursor + 8)
            let method = readU16(data, cursor + 10)
            let compressed = Int(readU32(data, cursor + 20))
            let uncompressed = Int(readU32(data, cursor + 24))
            let nameLength = Int(readU16(data, cursor + 28))
            let extraLength = Int(readU16(data, cursor + 30))
            let commentLength = Int(readU16(data, cursor + 32))
            let external = readU32(data, cursor + 38)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw LauncherError(.ioFailure, "Corrupt ZIP file name")
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw LauncherError(.ioFailure, "ZIP entry name is not UTF-8")
            }
            guard flags & 0x1 == 0 else {
                throw LauncherError(.ioFailure, "Encrypted ZIP entries are not supported")
            }
            guard method == 0 || method == 8 else {
                throw LauncherError(.ioFailure, "Unsupported ZIP compression method \(method)")
            }
            _ = compressed
            let mode = (external >> 16) & 0xFFFF
            let isDirectory = name.hasSuffix("/") || (mode & 0xF000) == 0x4000
            let isSymlink = (mode & 0xF000) == 0xA000
            entries.append(ZIPCentralEntry(
                name: name,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                uncompressedSize: uncompressed
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func findEOCD(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lower = max(0, data.count - 65_557)
        var index = data.count - 22
        while index >= lower {
            if readU32(data, index) == 0x0605_4b50 { return index }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
