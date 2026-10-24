import Foundation

/// Dynamic coding key used by strict decoders that must reject unknown fields.
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public let stringValue: String
    public let intValue: Int?

    public init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(stringValue: String) {
        self.init(stringValue)
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// Returns the decoded object's keys that are not in `known`.
    public func unknownKeys(known: Set<String>) -> [String] {
        allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
    }
}

/// Decodes a JSON value that may be either a single string or an array of strings.
///
/// Mojang uses both shapes for `arguments` entries (`value` field) and for a few other
/// polymorphic fields. Arrays are expanded into multiple argv elements, never joined.
public struct StringOrArray: Decodable, Sendable, Equatable {
    public let values: [String]

    public init(_ values: [String]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self.values = [single]
            return
        }
        self.values = try container.decode([String].self)
    }
}

extension Data {
    /// Decodes JSON with a stable key strategy and maps failures to `LauncherError.invalidMetadata`.
    public func decodeLauncherJSON<T: Decodable>(_ type: T.Type, context: String) throws -> T {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(type, from: self)
        } catch {
            throw LauncherError.metadata(error, context: context)
        }
    }
}
