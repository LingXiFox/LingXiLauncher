import Foundation
import LauncherCore

public struct WindowsProcessInspector: ProcessInspecting {
    public init() {}

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\tasklist.exe")
        process.arguments = ["/FI", "PID eq \(pid)", "/NH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return false }
        guard process.terminationStatus == 0 else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.contains(String(pid))
    }

    public func terminate(pid: Int32, force: Bool) throws {
        guard pid > 0 else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\taskkill.exe")
        process.arguments = force ? ["/PID", String(pid), "/T", "/F"] : ["/PID", String(pid), "/T"]
        do { try process.run(); process.waitUntilExit() } catch {
            throw LauncherError(.launchFailed, "Cannot terminate process \(pid): \(error.localizedDescription)")
        }
    }
}
