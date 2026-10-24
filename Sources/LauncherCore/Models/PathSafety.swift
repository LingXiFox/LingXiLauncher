import Foundation

/// Path helpers shared by every component that maps metadata strings onto the local filesystem.
///
/// Mojang metadata (library paths, asset hashes, native archive entries) is external input:
/// it must never be able to escape a cached directory or overwrite arbitrary files.
public enum PathSafety {
    /// Validates a single path component used as a directory name (a version id, an instance id).
    @discardableResult
    public static func validatedPathComponent(_ component: String) throws -> String {
        guard !component.isEmpty else {
            throw LauncherError(.pathEscapesRoot, "Empty path component", suggestion: "Provide a non-empty id.")
        }
        guard component != ".", component != ".." else {
            throw LauncherError(.pathEscapesRoot, "Illegal path component '\(component)'")
        }
        let forbidden = CharacterSet(charactersIn: "/\\\u{0}")
            .union(.newlines)
            .union(.controlCharacters)
        guard component.rangeOfCharacter(from: forbidden) == nil else {
            throw LauncherError(.pathEscapesRoot, "Path component '\(component)' contains illegal characters")
        }
        return component
    }

    /// Joins a metadata-provided relative path onto a base directory, refusing escapes.
    public static func safeJoin(base: URL, relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LauncherError(.pathEscapesRoot, "Empty relative path while joining \(base.path)")
        }
        guard !trimmed.hasPrefix("/") else {
            throw LauncherError(.pathEscapesRoot, "Absolute path '\(relativePath)' is not allowed under \(base.path)")
        }
        guard !trimmed.contains("\\") else {
            throw LauncherError(.pathEscapesRoot, "Backslash in relative path '\(relativePath)'")
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LauncherError(.pathEscapesRoot, "Control character in relative path '\(relativePath)'")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else {
            throw LauncherError(.pathEscapesRoot, "Empty relative path while joining \(base.path)")
        }
        for component in components {
            guard component != ".", component != ".." else {
                throw LauncherError(.pathEscapesRoot, "Path traversal component in '\(relativePath)'")
            }
        }
        let candidate = base.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
        guard isContained(candidate, inBase: base) else {
            throw LauncherError(.pathEscapesRoot, "Path '\(relativePath)' escapes \(base.path)")
        }
        return candidate
    }

    /// True when `candidate` (after standardisation) lives inside `base`.
    public static func isContained(_ candidate: URL, inBase base: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if candidatePath == basePath { return true }
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    /// True when `candidate` stays inside `base` even after resolving symlinks.
    public static func isContainedResolvingSymlinks(_ candidate: URL, inBase base: URL) -> Bool {
        isContained(candidate.resolvingSymlinksInPath(), inBase: base.resolvingSymlinksInPath())
    }

    /// Validates a single archive entry name (ZIP path) before extracting it.
    ///
    /// Rejects absolute paths, Windows drive letters, parent traversal, backslashes and
    /// control characters. The caller must still verify the extraction root afterwards
    /// (symlink escape protection).
    @discardableResult
    public static func validatedArchiveEntry(_ entry: String) throws -> String {
        guard !entry.isEmpty else {
            throw LauncherError(.pathEscapesRoot, "Empty archive entry name")
        }
        guard !entry.hasPrefix("/"), !entry.hasPrefix("\\") else {
            throw LauncherError(.pathEscapesRoot, "Absolute archive entry '\(entry)'")
        }
        guard entry.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) == nil else {
            throw LauncherError(.pathEscapesRoot, "Drive-qualified archive entry '\(entry)'")
        }
        guard !entry.contains("\\") else {
            throw LauncherError(.pathEscapesRoot, "Backslash in archive entry '\(entry)'")
        }
        guard entry.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LauncherError(.pathEscapesRoot, "Control character in archive entry '\(entry)'")
        }
        for component in entry.split(separator: "/", omittingEmptySubsequences: false) {
            guard component != ".." else {
                throw LauncherError(.pathEscapesRoot, "Archive entry '\(entry)' attempts path traversal")
            }
        }
        return entry
    }
}
