import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A cross-process record of which instance owns a live game process.
///
/// The GUI and CLI must agree even when they are separate processes. This registry stores only
/// an instance id, pid and timestamp outside the instance game directory. A missing registry or
/// a dead pid fails closed only for the process check, never by deleting game data.
public protocol InstanceRuntimeChecking: Sendable {
    func isRunning(instanceID: String) -> Bool
}

public struct InstanceRuntimeRegistry: InstanceRuntimeChecking, Sendable {
    private struct Record: Codable, Sendable {
        let instanceID: String
        let pid: Int32
        let executable: String
        let startedAt: Date
    }

    private let directory: URL
    private var fileManager: FileManager { FileManager.default }

    public init(layout: GameDataLayout) {
        self.directory = layout.dataRoot.appendingPathComponent("runtime/instances", isDirectory: true)
    }

    public func recordURL(instanceID: String) throws -> URL {
        let component = try PathSafety.validatedPathComponent(instanceID)
        return directory.appendingPathComponent("\(component).json", isDirectory: false)
    }

    public func markRunning(instanceID: String, pid: Int32, executable: URL? = nil) throws {
        guard pid > 0 else { throw LauncherError(.launchFailed, "Invalid game process id") }
        let url = try recordURL(instanceID: instanceID)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = Record(
                instanceID: instanceID,
                pid: pid,
                executable: executable?.path ?? "",
                startedAt: Date()
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw LauncherError(.ioFailure, "Cannot record running instance: \(error.localizedDescription)")
        }
    }

    public func clear(instanceID: String) {
        guard let url = try? recordURL(instanceID: instanceID) else { return }
        try? fileManager.removeItem(at: url)
    }

    public func isRunning(instanceID: String) -> Bool {
        guard let url = try? recordURL(instanceID: instanceID),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.instanceID == instanceID else {
            return false
        }
        guard Self.processExists(record.pid) else {
            try? fileManager.removeItem(at: url)
            return false
        }
        return true
    }

    public func runningProcessIdentifier(instanceID: String) -> Int32? {
        guard isRunning(instanceID: instanceID),
              let url = try? recordURL(instanceID: instanceID),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return nil
        }
        return record.pid
    }

    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if canImport(Darwin)
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
        #else
        return false
        #endif
    }
}
