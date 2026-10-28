import CryptoKit
import Foundation

/// SHA-1 helpers.
///
/// SHA-1 is used because Mojang's published metadata only provides SHA-1 plus size. It is a
/// compatibility checksum, not a modern tamper-proof signature; TLS is the transport guarantee.
public enum SHA1 {
    public static func hexDigest(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming digest of a file, so multi-hundred-megabyte assets never load into memory.
    public static func hexDigest(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        do {
            while true {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(url.path): \(error.localizedDescription)")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// SHA-256 helpers for trusted runtime archives (Adoptium publishes SHA-256).
public enum SHA256Digest {
    public static func hexDigest(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDigest(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        do {
            while true {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(url.path): \(error.localizedDescription)")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// SHA-512 helpers for Modrinth file hashes when the API supplies them.
public enum SHA512Digest {
    public static func hexDigest(_ data: Data) -> String {
        CryptoKit.SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDigest(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA512()
        do {
            while true {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(url.path): \(error.localizedDescription)")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
