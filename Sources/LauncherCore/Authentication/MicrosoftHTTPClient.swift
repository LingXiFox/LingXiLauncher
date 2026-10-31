import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction for Microsoft/Xbox/Minecraft endpoints.
///
/// Injected so the whole authentication flow can be unit-tested without network access, and so
/// no token can accidentally be logged by the transport.
public struct MicrosoftHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct MicrosoftHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]

    public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }

    public func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LauncherError(
                .invalidMetadata,
                "Unexpected JSON response (HTTP \(statusCode)): \(responseSnippet)",
                suggestion: "The service may have changed its response format; check the endpoint."
            )
        }
    }

    /// Bounded, single-line response text for diagnostics. Never call this on requests containing
    /// tokens; responses from these services do not echo credentials.
    public var responseSnippet: String {
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}

public protocol MicrosoftHTTPClient: Sendable {
    func send(_ request: MicrosoftHTTPRequest) async throws -> MicrosoftHTTPResponse
}

/// URLSession-backed transport. No redirects for API calls, no cookies, no shared cache.
public struct URLSessionMicrosoftHTTPClient: MicrosoftHTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 60)
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: MicrosoftHTTPRequest) async throws -> MicrosoftHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw LauncherError(.networkFailure, "Non-HTTP response from \(request.url.host ?? "?")")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return MicrosoftHTTPResponse(statusCode: http.statusCode, data: data, headers: headers)
        } catch let error as LauncherError {
            throw error
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                throw LauncherError(.authenticationCancelled, "Request cancelled")
            }
            throw LauncherError(.networkFailure, "Network error contacting \(request.url.host ?? "?"): \(nsError.localizedDescription)")
        }
    }
}
