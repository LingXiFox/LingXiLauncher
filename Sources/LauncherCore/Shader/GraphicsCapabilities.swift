import Foundation
import OpenGL
import OpenGL.GL3

/// Actual OpenGL environment available to the Java process on this Mac.
///
/// macOS exposes OpenGL 4.1 at most, even on Apple Silicon. Metal ray-tracing features are not
/// available to Minecraft Java / Iris, so this type deliberately reports only the OpenGL context
/// we can create and query, never a synthetic "Metal RTX" capability.
public struct GraphicsCapabilities: Sendable, Equatable {
    public let openGLVersion: String?
    public let renderer: String?
    public let shadingLanguageVersion: String?
    public let isAppleSilicon: Bool
    public let probeError: String?

    public init(
        openGLVersion: String?,
        renderer: String?,
        shadingLanguageVersion: String?,
        isAppleSilicon: Bool,
        probeError: String?
    ) {
        self.openGLVersion = openGLVersion
        self.renderer = renderer
        self.shadingLanguageVersion = shadingLanguageVersion
        self.isAppleSilicon = isAppleSilicon
        self.probeError = probeError
    }

    public var openGLMajor: Int? {
        guard let openGLVersion else { return nil }
        return Int(openGLVersion.split(separator: ".").first ?? "")
    }

    public var openGLMinor: Int? {
        guard let openGLVersion else { return nil }
        let parts = openGLVersion.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1].prefix(while: \Character.isNumber))
    }

    /// True when the host reports at most OpenGL 4.1, the fixed maximum on macOS.
    public var isLegacyOpenGL: Bool {
        guard let major = openGLMajor else { return true }
        if major < 4 { return true }
        guard major == 4, let minor = openGLMinor else { return false }
        return minor <= 1
    }

    public var summary: String {
        if let openGLVersion, let renderer {
            return "OpenGL \(openGLVersion) · \(renderer)"
        }
        return "OpenGL 信息不可用"
    }

    /// This is a warning, not a claim that every shader pack fails. Iris may fall back for some
    /// packs, but compute/SSBO/GL 4.3+ features cannot be provided by macOS OpenGL.
    public var shaderCompatibilityWarning: String? {
        guard let openGLVersion else {
            return "无法获取 OpenGL 版本；不能确认光影可渲染，请以游戏内 Iris 日志为准。"
        }
        if isLegacyOpenGL {
            return "macOS 提供 OpenGL \(openGLVersion)，部分使用 GL 4.3+ / compute shader 的光影可能无法编译；这不代表所有光影都不可用，也不等同于 Metal 光追支持。"
        }
        return nil
    }

    public static func current() -> GraphicsCapabilities {
        let appleSilicon = (try? PlatformContext.current())?.hostArchitecture == .arm64
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
            return GraphicsCapabilities(
                openGLVersion: nil,
                renderer: nil,
                shadingLanguageVersion: nil,
                isAppleSilicon: appleSilicon,
                probeError: "CGLChoosePixelFormat failed (\(chooseResult))"
            )
        }
        var context: CGLContextObj?
        let createResult = CGLCreateContext(pixelFormat, nil, &context)
        CGLDestroyPixelFormat(pixelFormat)
        guard createResult == kCGLNoError, let context else {
            return GraphicsCapabilities(
                openGLVersion: nil,
                renderer: nil,
                shadingLanguageVersion: nil,
                isAppleSilicon: appleSilicon,
                probeError: "CGLCreateContext failed (\(createResult))"
            )
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
