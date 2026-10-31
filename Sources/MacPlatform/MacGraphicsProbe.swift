import Foundation
import OpenGL
import OpenGL.GL3
import LauncherCore

public struct MacGraphicsProbe: GraphicsProbing {
    public init() {}

    public func current() -> GraphicsCapabilities {
        let appleSilicon = PlatformContext.hardwareArchitecture() == .arm64
        var attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(kCGLOGLPVersion_GL4_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            CGLPixelFormatAttribute(0),
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        let chooseResult = CGLChoosePixelFormat(&attributes, &pixelFormat, &count)
        guard chooseResult == kCGLNoError, let pixelFormat else {
            return GraphicsCapabilities(openGLVersion: nil, renderer: nil, shadingLanguageVersion: nil, isAppleSilicon: appleSilicon, probeError: "CGLChoosePixelFormat failed (\(chooseResult))")
        }
        var context: CGLContextObj?
        let createResult = CGLCreateContext(pixelFormat, nil, &context)
        CGLDestroyPixelFormat(pixelFormat)
        guard createResult == kCGLNoError, let context else {
            return GraphicsCapabilities(openGLVersion: nil, renderer: nil, shadingLanguageVersion: nil, isAppleSilicon: appleSilicon, probeError: "CGLCreateContext failed (\(createResult))")
        }
        CGLSetCurrentContext(context)
        defer {
            CGLSetCurrentContext(nil)
            CGLDestroyContext(context)
        }
        let version = glGetString(GLenum(GL_VERSION)).map { String(cString: $0) }
        let renderer = glGetString(GLenum(GL_RENDERER)).map { String(cString: $0) }
        let shading = glGetString(GLenum(GL_SHADING_LANGUAGE_VERSION)).map { String(cString: $0) }
        return GraphicsCapabilities(
            openGLVersion: version,
            renderer: renderer,
            shadingLanguageVersion: shading,
            isAppleSilicon: appleSilicon,
            probeError: version == nil ? "glGetString(GL_VERSION) returned nil" : nil
        )
    }
}
