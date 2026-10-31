import Foundation

/// Portable facade over the platform ZIP implementation. The security policy and public API
/// stay in Core; Apple Compression and Windows archive APIs remain platform details.
public enum SafeZipExtractor {
    public typealias Limits = ArchiveLimits
    public typealias ExtractedEntry = ArchiveExtractedEntry

    @discardableResult
    public static func extract(
        archive: URL,
        into directory: URL,
        excluding excludedPrefixes: [String] = [],
        limits: Limits = Limits()
    ) throws -> [ExtractedEntry] {
        try PlatformRuntime.archive.extract(
            archive: archive,
            into: directory,
            excluding: excludedPrefixes,
            limits: limits
        )
    }

    public static func readEntries(_ data: Data, limits: Limits = Limits()) throws -> [ArchiveEntry] {
        try PlatformRuntime.archive.readEntries(data, limits: limits)
    }
}
