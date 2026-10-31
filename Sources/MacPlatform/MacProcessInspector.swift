import Foundation
import Darwin
import LauncherCore

public struct MacProcessInspector: ProcessInspecting {
    public init() {}

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func terminate(pid: Int32, force: Bool) throws {
        guard pid > 0 else { return }
        if kill(pid, force ? SIGKILL : SIGTERM) != 0, errno != ESRCH {
            throw LauncherError(.launchFailed, "Cannot terminate process \(pid): errno \(errno)")
        }
    }
}
