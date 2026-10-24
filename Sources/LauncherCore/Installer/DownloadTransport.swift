import Foundation

/// Failures raised by a `DownloadTransport`. Kept separate from `LauncherError` so the
/// downloader can decide what is retryable / whether another source may help.
public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// DNS failure, connection reset, TLS error, timeout, ... — retryable.
    case network(String)
    /// HTTP status code. 403/404 are terminal for this source; 408/429/5xx are retryable.
    case httpStatus(Int)
    /// Response was not an HTTP response (or body was unusable).
    case invalidResponse(String)
    /// Writing the downloaded bytes locally failed (permissions, disk full, ...).
    case localIO(String)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .network:
            return true
        case let .httpStatus(status):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .invalidResponse, .localIO, .cancelled:
            return false
        }
    }

    public var description: String {
        switch self {
        case let .network(message): return "network error: \(message)"
        case let .httpStatus(status): return "HTTP \(status)"
        case let .invalidResponse(message): return "invalid response: \(message)"
        case let .localIO(message): return "local I/O error: \(message)"
        case .cancelled: return "cancelled"
        }
    }
}

/// Byte transport used by the installer. Injected so the downloader is fully testable without
/// touching the network, and so `local-cache-only` can be enforced by never calling it.
public protocol DownloadTransport: Sendable {
    /// Fetches a small resource (manifest, version JSON, asset index) into memory.
    func fetch(from url: URL) async throws -> Data

    /// Downloads `url` into the file at `destination` (which the caller owns and may delete).
    /// Implementations must not write a partial body to `destination` on failure.
    func download(from url: URL, to destination: URL) async throws
}

/// Real HTTPS transport built on URLSession.
public struct URLSessionTransport: DownloadTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 60, resourceTimeout: TimeInterval = 600) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func fetch(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(URLSessionTransport.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response)
            return data
        } catch let error as TransportError {
            throw error
        } catch {
            throw URLSessionTransport.map(error)
        }
    }

    public func download(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue(URLSessionTransport.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (temporaryURL, response) = try await session.download(for: request)
            try validate(response)
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destination)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fileManager.moveItem(at: temporaryURL, to: destination)
            } catch {
                // Cross-volume moves are not atomic; fall back to copy + delete. The downloader
                // verifies the copy and only then renames it into place.
                try fileManager.copyItem(at: temporaryURL, to: destination)
                try? fileManager.removeItem(at: temporaryURL)
            }
        } catch let error as TransportError {
            throw error
        } catch {
            throw URLSessionTransport.map(error)
        }
    }

    static let userAgent = "LingXiLauncher/\(LauncherInfo.version) (macOS; +https://github.com/)"

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.invalidResponse("not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw TransportError.httpStatus(http.statusCode)
        }
    }

    private static func map(_ error: Error) -> TransportError {
        if let transportError = error as? TransportError { return transportError }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled { return .cancelled }
            return .network("\(nsError.localizedDescription) (URLError \(nsError.code))")
        }
        return .network(nsError.localizedDescription)
    }
}
