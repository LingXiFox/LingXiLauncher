import Foundation
import LauncherCore

public struct WindowsGraphicsProbe: GraphicsProbing {
    public init() {}
    public func current() -> GraphicsCapabilities {
        GraphicsCapabilities(openGLVersion: nil, renderer: nil, shadingLanguageVersion: nil,
            isAppleSilicon: false, probeError: "OpenGL capability probing is macOS-only in this build")
    }
}
