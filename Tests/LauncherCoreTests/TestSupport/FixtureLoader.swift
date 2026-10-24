import Foundation

/// Loads test fixtures that are copied into the test bundle (`Bundle.module`).
enum FixtureLoader {
    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)

        var description: String {
            switch self {
            case let .notFound(name): return "Fixture not found in test bundle: \(name)"
            }
        }
    }

    static func url(_ relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let file = parts.last else { throw FixtureError.notFound(relativePath) }
        var directory = "Fixtures"
        if parts.count > 1 {
            directory += "/" + parts.dropLast().joined(separator: "/")
        }
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: name, withExtension: ext.isEmpty ? nil : ext, subdirectory: directory) else {
            throw FixtureError.notFound(relativePath)
        }
        return url
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: try url(relativePath))
    }

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: try url(relativePath), encoding: .utf8)
    }

    /// Creates a unique temporary directory that the caller owns.
    static func temporaryDirectory(_ label: String = "lingxi-tests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
