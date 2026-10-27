import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Opens the system browser. Implemented by CLI/GUI (AppKit), not by LauncherCore.
public protocol BrowserOpening: Sendable {
    func open(_ url: URL) throws
}

/// Performs an Authorization Code + PKCE round-trip and returns the code with its state.
public protocol OAuthAuthorizing: Sendable {
    func authorize(
        configuration: MicrosoftAuthenticationConfiguration,
        state: String,
        codeChallenge: String,
        timeout: TimeInterval
    ) async throws -> OAuthCallback
}

/// Runs a tiny loopback HTTP server, opens the system browser and waits for the redirect.
public struct LoopbackOAuthAuthorizer: OAuthAuthorizing {
    private let browser: any BrowserOpening
    private let host: String

    public init(browser: any BrowserOpening, host: String = "127.0.0.1") {
        self.browser = browser
        self.host = host
    }

    public func authorize(
        configuration: MicrosoftAuthenticationConfiguration,
        state: String,
        codeChallenge: String,
        timeout: TimeInterval
    ) async throws -> OAuthCallback {
        let server = LoopbackCallbackServer(host: host)
        let port = try server.start()
        let redirectURI = configuration.redirectURI(port: port)
        let authorizationURL = MicrosoftOAuthClient.authorizationURL(
            configuration: configuration,
            state: state,
            codeChallenge: codeChallenge,
            redirectURI: redirectURI
        )

        do {
            try browser.open(authorizationURL)
        } catch {
            server.stop()
            throw LauncherError(
                .unauthorized,
                "Could not open the system browser for Microsoft sign-in: \(error.localizedDescription)",
                suggestion: "Open the authorization URL manually and complete the sign-in."
            )
        }

        do {
            return try await withThrowingTaskGroup(of: OAuthCallback.self) { group in
                group.addTask {
                    try await server.waitForCallback()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                    throw LauncherError(
                        .authenticationTimeout,
                        "Microsoft sign-in timed out after \(Int(timeout)) seconds",
                        suggestion: "Retry sign-in; the local callback listener was closed."
                    )
                }
                defer {
                    group.cancelAll()
                    server.stop()
                }
                guard let callback = try await group.next() else {
                    throw LauncherError(.authenticationCancelled, "Microsoft sign-in was cancelled")
                }
                guard callback.state == state else {
                    throw LauncherError(
                        .unauthorized,
                        "Microsoft sign-in returned a mismatched OAuth state; the response was ignored",
                        suggestion: "Retry sign-in. Do not reuse authorization URLs."
                    )
                }
                return OAuthCallback(code: callback.code, state: callback.state, redirectURI: redirectURI)
            }
        } catch let error as LauncherError {
            if error.code == .authenticationCancelled || error.code == .authenticationTimeout {
                throw error
            }
            throw error
        }
    }
}

/// A one-shot HTTP server bound to 127.0.0.1 that receives the OAuth redirect.
public final class LoopbackCallbackServer: @unchecked Sendable {
    private let host: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var portValue: UInt16 = 0
    private var closed = false
    private var callbackStream: AsyncStream<OAuthCallbackResult>!
    private var callbackContinuation: AsyncStream<OAuthCallbackResult>.Continuation?

    public enum OAuthCallbackResult: Sendable, Equatable {
        case success(OAuthCallback)
        case failure(message: String)
    }

    public init(host: String = "127.0.0.1") {
        self.host = host
    }

    deinit {
        stop()
    }

    /// Binds to a random loopback port and starts accepting one request.
    public func start() throws -> UInt16 {
        let pair = AsyncStream<OAuthCallbackResult>.makeStream(bufferingPolicy: .bufferingNewest(1))
        callbackStream = pair.stream
        callbackContinuation = pair.continuation

        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else {
            throw LauncherError(.networkFailure, "Could not create the OAuth callback socket")
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr(host)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw LauncherError(.networkFailure, "Could not bind the OAuth callback listener on \(host)")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw LauncherError(.networkFailure, "Could not determine the OAuth callback port")
        }
        lock.lock()
        listenFD = fd
        portValue = UInt16(bigEndian: bound.sin_port)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
        return portValue
    }

    /// Waits for a redirect. Returns a failure result for `error=` responses.
    public func waitForCallback() async throws -> OAuthCallback {
        for await result in callbackStream {
            switch result {
            case let .success(callback):
                return callback
            case let .failure(message):
                throw LauncherError(
                    .authenticationCancelled,
                    "Microsoft sign-in was cancelled or rejected: \(message)"
                )
            }
        }
        throw LauncherError(.authenticationCancelled, "Microsoft sign-in was cancelled")
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        let alreadyClosed = closed
        closed = true
        callbackContinuation?.finish()
        callbackContinuation = nil
        lock.unlock()

        guard !alreadyClosed, fd >= 0 else { return }
        #if canImport(Darwin) || canImport(Glibc)
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
        #endif
    }

    private func acceptLoop() {
        lock.lock()
        let fd = listenFD
        lock.unlock()
        guard fd >= 0 else { return }

        // Poll in one-second slices so a close()/timeout on another thread releases this
        // background thread promptly instead of waiting for the full 300 s.
        var ready: Int32 = 0
        for _ in 0..<300 {
            if isClosed { return }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            ready = poll(&pollDescriptor, 1, 1_000)
            if ready != 0 { break }
        }
        guard ready > 0 else {
            finish(.failure(message: "callback listener timed out"))
            return
        }

        var clientAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(fd, $0, &addressLength)
            }
        }
        guard clientFD >= 0 else {
            finish(.failure(message: "callback connection was not accepted"))
            return
        }
        defer { close(clientFD) }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 32_768 {
            let received = recv(clientFD, &buffer, buffer.count, 0)
            guard received > 0 else { break }
            request.append(buffer, count: received)
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)),
              let requestText = String(data: request[..<headerEnd.lowerBound], encoding: .utf8),
              let requestLine = requestText.split(separator: "\r\n").first else {
            sendResponse(clientFD, status: "400 Bad Request", body: "Invalid callback request")
            finish(.failure(message: "invalid callback request"))
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(clientFD, status: "400 Bad Request", body: "Invalid callback request")
            finish(.failure(message: "invalid callback request line"))
            return
        }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            sendResponse(clientFD, status: "400 Bad Request", body: "Invalid callback URL")
            finish(.failure(message: "invalid callback URL"))
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        if let error = value("error") {
            sendResponse(clientFD, status: "200 OK", body: "Sign-in was cancelled. You can close this window.")
            finish(.failure(message: value("error_description") ?? error))
            return
        }
        guard let code = value("code"), let state = value("state"), !code.isEmpty, !state.isEmpty else {
            sendResponse(clientFD, status: "400 Bad Request", body: "Missing authorization code")
            finish(.failure(message: "missing authorization code"))
            return
        }
        sendResponse(clientFD, status: "200 OK", body: "LingXi Launcher sign-in completed. You can close this window.")
        finish(.success(OAuthCallback(code: code, state: state, redirectURI: URL(string: "http://localhost\(target)")!)))
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func finish(_ result: OAuthCallbackResult) {
        lock.lock()
        let continuation = callbackContinuation
        callbackContinuation = nil
        lock.unlock()
        continuation?.yield(result)
        continuation?.finish()
    }

    private func sendResponse(_ fd: Int32, status: String, body: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>LingXi Launcher</title></head>\
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:40px">\
        <h1>LingXi Launcher</h1><p>\(body)</p></body></html>
        """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = response.withCString { pointer in
            send(fd, pointer, strlen(pointer), 0)
        }
    }
}
