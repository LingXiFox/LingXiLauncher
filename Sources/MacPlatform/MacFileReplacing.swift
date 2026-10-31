import Foundation
import LauncherCore

public struct MacFileReplacing: FileReplacing {
    public init() {}
    public func replaceItem(at destination: URL, with item: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: item)
        } else {
            try FileManager.default.moveItem(at: item, to: destination)
        }
    }
}
