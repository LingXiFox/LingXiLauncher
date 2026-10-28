import Foundation
import Network

/// Opt-in, loopback-only automation for debugging the real SwiftUI actions.
///
/// It is disabled unless `LINGXI_DEBUG_AUTOMATION=1` (or `--debug-automation` is passed).
/// Views register the exact action they bind to their visible controls; the debug server never
/// fabricates a separate business path. The protocol is one JSON object per line over TCP.
@MainActor
final class DebugAutomationCenter {
    static let shared = DebugAutomationCenter()

    typealias Handler = @MainActor (_ params: [String: String]) async -> [String: Any]
    private struct Command: Decodable {
        let action: String
        let params: [String: String]?
    }
    private struct Registration {
        let name: String
        let handler: Handler
    }

    private var listener: NWListener?
    private var handlers: [UUID: Registration] = [:]
    private var started = false

    private init() {}

    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LINGXI_DEBUG_AUTOMATION"] == "1"
            || CommandLine.arguments.contains("--debug-automation")
    }

    func startIfEnabled() {
        guard isEnabled, !started else { return }
        started = true
        let portValue = UInt16(ProcessInfo.processInfo.environment["LINGXI_DEBUG_AUTOMATION_PORT"] ?? "59321") ?? 59321
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: portValue)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    fputs("debug automation listener failed: \(error)\n", stderr)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            fputs("debug automation listening on 127.0.0.1:\(portValue)\n", stderr)
        } catch {
            fputs("debug automation failed to start: \(error)\n", stderr)
        }
    }

    @discardableResult
    func register(_ name: String, handler: @escaping Handler) -> UUID {
        let token = UUID()
        handlers[token] = Registration(name: name, handler: handler)
        return token
    }

    func unregister(_ token: UUID) {
        handlers.removeValue(forKey: token)
    }

    // MARK: - Socket

    private func accept(_ connection: NWConnection) {
        guard case let .hostPort(host, _) = connection.endpoint,
              "\(host)".contains("127.0.0.1") || "\(host)".contains("::1") else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    self.handleLine(Data(line), connection: connection)
                    return
                }
                if complete || error != nil || buffer.count > 1 << 20 {
                    connection.cancel()
                    return
                }
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func handleLine(_ data: Data, connection: NWConnection) {
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else {
            respond(["ok": false, "error": "invalid JSON command"], to: connection)
            return
        }
        if command.action == "debug.actions" {
            respond(["ok": true, "actions": handlers.values.map(\.name).sorted()], to: connection)
            return
        }
        guard let registration = handlers.values.first(where: { $0.name == command.action }) else {
            respond(["ok": false, "error": "action not registered: \(command.action)"], to: connection)
            return
        }
        Task { @MainActor in
            var result = await registration.handler(command.params ?? [:])
            result["ok"] = result["ok"] ?? true
            result["action"] = command.action
            self.respond(result, to: connection)
        }
    }

    private func respond(_ object: [String: Any], to connection: NWConnection) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            connection.cancel()
            return
        }
        var line = data
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { _ in connection.cancel() })
    }
}
