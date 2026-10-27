import SwiftUI

// MARK: - Appearance

enum LXAppearance: String, CaseIterable, Identifiable, Hashable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        case .system: return "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

// MARK: - Theme

struct LXTheme {
    let colorScheme: ColorScheme

    var isDark: Bool { colorScheme == .dark }

    var canvas: Color { isDark ? Color(hex: 0x0D0F12) : Color(hex: 0xF4F1EB) }
    var sidebar: Color { isDark ? Color(hex: 0x101319) : Color(hex: 0xEDE8E0) }
    var surface: Color { isDark ? Color(hex: 0x15191F) : Color(hex: 0xFFFFFF) }
    var surfaceRaised: Color { isDark ? Color(hex: 0x1B2028) : Color(hex: 0xFAF7F2) }
    var surfaceHover: Color { isDark ? Color(hex: 0x222933) : Color(hex: 0xF0EAE1) }
    var sidebarActive: Color { isDark ? Color(hex: 0x1D242D) : Color(hex: 0xE4DCD1) }
    var border: Color { isDark ? Color(hex: 0x282F39) : Color(hex: 0xE1D9CE) }
    var borderStrong: Color { isDark ? Color(hex: 0x39424E) : Color(hex: 0xCEC3B5) }
    var text: Color { isDark ? Color(hex: 0xF4F0E8) : Color(hex: 0x1B1D21) }
    var textSecondary: Color { isDark ? Color(hex: 0xA8B0BB) : Color(hex: 0x5E646C) }
    var textTertiary: Color { isDark ? Color(hex: 0x8A93A0) : Color(hex: 0x6E757E) }

    var orange: Color { isDark ? Color(hex: 0xF29A5F) : Color(hex: 0xBF5A22) }
    var orangeStrong: Color { isDark ? Color(hex: 0xFFB37B) : Color(hex: 0xA84C17) }
    var orangeSoft: Color { orange.opacity(isDark ? 0.14 : 0.11) }
    var onOrange: Color { isDark ? Color(hex: 0x1C120A) : Color(hex: 0xFFF9F2) }

    var success: Color { isDark ? Color(hex: 0x83D3A5) : Color(hex: 0x256B4B) }
    var warning: Color { isDark ? Color(hex: 0xE7B86C) : Color(hex: 0x7A530F) }
    var danger: Color { isDark ? Color(hex: 0xE5837D) : Color(hex: 0xA33E39) }
    var info: Color { isDark ? Color(hex: 0x8CB9D4) : Color(hex: 0x2C607C) }

    var shadow: Color { Color.black.opacity(isDark ? 0.28 : 0.08) }

    var terminalBackground: Color { Color(hex: 0x0A0C10) }
    var terminalChrome: Color { Color(hex: 0x11151B) }
    var terminalText: Color { Color(hex: 0xD6DDE6) }
    var terminalDim: Color { Color(hex: 0x707A87) }
    var terminalBorder: Color { Color(hex: 0x262E38) }
}

private struct LXThemeKey: EnvironmentKey {
    static let defaultValue = LXTheme(colorScheme: .dark)
}

extension EnvironmentValues {
    var lxTheme: LXTheme {
        get { self[LXThemeKey.self] }
        set { self[LXThemeKey.self] = newValue }
    }
}

extension View {
    func lxTheme(_ scheme: ColorScheme) -> some View {
        environment(\.lxTheme, LXTheme(colorScheme: scheme))
    }
}

// MARK: - Typography

enum LXFont {
    static func display(_ size: CGFloat = 34) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static func title(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyStrong = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
    static let captionStrong = Font.system(size: 11, weight: .medium)
    static let overline = Font.system(size: 9, weight: .semibold)
    static let button = Font.system(size: 13, weight: .semibold)
    static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, weight: .regular, design: .monospaced)
}

enum LXSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
}

enum LXRadius {
    static let sm: CGFloat = 7
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let xl: CGFloat = 18
}

// MARK: - Color helper

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Text styles

struct LXOverline: View {
    @Environment(\.lxTheme) private var theme
    let text: String
    var color: Color?

    var body: some View {
        Text(text.uppercased())
            .font(LXFont.overline)
            .tracking(1.5)
            .foregroundStyle(color ?? theme.textTertiary)
    }
}

struct LXPageHeader<Trailing: View>: View {
    @Environment(\.lxTheme) private var theme
    let eyebrow: String
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: Trailing

    init(eyebrow: String, title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: LXSpace.md) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Rectangle()
                        .fill(theme.orange)
                        .frame(width: 16, height: 2)
                        .clipShape(Capsule())
                    LXOverline(text: eyebrow, color: theme.orange)
                }
                Text(title)
                    .font(LXFont.display(28))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(LXFont.body)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: LXSpace.md)
            trailing
        }
    }
}

extension LXPageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Card

struct LXCard<Content: View>: View {
    @Environment(\.lxTheme) private var theme
    var padding: CGFloat = LXSpace.lg
    var selected: Bool = false
    var elevated: Bool = false
    var accent: Color? = nil
    @ViewBuilder let content: Content

    init(
        padding: CGFloat = LXSpace.lg,
        selected: Bool = false,
        elevated: Bool = false,
        accent: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.selected = selected
        self.elevated = elevated
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                    .fill(elevated ? theme.surfaceRaised : theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                    .strokeBorder(
                        selected ? theme.orange.opacity(0.55) : theme.border,
                        lineWidth: selected ? 1.2 : 1
                    )
            )
            .overlay(alignment: .topLeading) {
                if let accent {
                    Capsule()
                        .fill(accent)
                        .frame(width: 28, height: 3)
                        .padding(.top, 1)
                        .padding(.leading, padding)
                }
            }
            .shadow(color: theme.shadow, radius: elevated ? 18 : 10, x: 0, y: elevated ? 8 : 4)
    }
}

// MARK: - Badge

enum LXBadgeTone {
    case neutral, accent, success, warning, danger, info
}

struct LXBadge: View {
    @Environment(\.lxTheme) private var theme
    let text: String
    var tone: LXBadgeTone = .neutral
    var icon: String? = nil
    var dot: Bool = false

    private var color: Color {
        switch tone {
        case .neutral: return theme.textSecondary
        case .accent: return theme.orange
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        case .info: return theme.info
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return theme.surfaceRaised
        case .accent: return theme.orangeSoft
        case .success: return theme.success.opacity(0.12)
        case .warning: return theme.warning.opacity(0.12)
        case .danger: return theme.danger.opacity(0.12)
        case .info: return theme.info.opacity(0.12)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(LXFont.captionStrong)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(tone == .neutral ? 0.18 : 0.22), lineWidth: 0.7))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

struct LXButton: View {
    enum Kind {
        case primary, secondary, ghost, destructive
    }

    @Environment(\.lxTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @FocusState private var focused: Bool

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .secondary
    var isDisabled: Bool = false
    var isFullWidth: Bool = false
    var help: String? = nil
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        kind: Kind = .secondary,
        isDisabled: Bool = false,
        isFullWidth: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.isDisabled = isDisabled
        self.isFullWidth = isFullWidth
        self.help = help
        self.action = action
    }

    private var foreground: Color {
        guard !isDisabled else { return theme.textTertiary }
        switch kind {
        case .primary: return theme.onOrange
        case .secondary: return theme.text
        case .ghost: return theme.textSecondary
        case .destructive: return theme.danger
        }
    }

    private var background: Color {
        guard !isDisabled else { return theme.surfaceRaised }
        switch kind {
        case .primary: return theme.orange
        case .secondary: return hovering ? theme.surfaceHover : theme.surfaceRaised
        case .ghost: return hovering ? theme.surfaceHover : .clear
        case .destructive: return theme.danger.opacity(hovering ? 0.18 : 0.10)
        }
    }

    private var border: Color {
        guard !isDisabled else { return theme.border }
        switch kind {
        case .primary: return theme.orangeStrong.opacity(0.45)
        case .secondary: return hovering ? theme.borderStrong : theme.border
        case .ghost: return .clear
        case .destructive: return theme.danger.opacity(0.28)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(LXFont.button)
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .background(background, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous)
                    .strokeBorder(focused ? theme.orange.opacity(0.8) : border, lineWidth: focused ? 1.3 : 0.8)
            )
            .shadow(
                color: kind == .primary && !isDisabled ? theme.orange.opacity(0.18) : .clear,
                radius: 12,
                x: 0,
                y: 6
            )
            .contentShape(RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
            .scaleEffect(reduceMotion ? 1 : (hovering && !isDisabled ? 1.012 : 1))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        .help(help ?? "")
        .accessibilityLabel(Text(title))
    }
}

struct LXIconButton: View {
    @Environment(\.lxTheme) private var theme
    @State private var hovering = false
    @FocusState private var focused: Bool
    let systemImage: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? theme.orange : theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous)
                        .fill(hovering ? theme.surfaceHover : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous)
                        .strokeBorder(focused ? theme.orange.opacity(0.8) : .clear, lineWidth: 1.2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

struct LXChip: View {
    @Environment(\.lxTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LXFont.captionStrong)
                .foregroundStyle(isSelected ? theme.orange : theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? theme.orangeSoft : .clear)
                )
                .overlay(
                    Capsule().strokeBorder(
                        focused ? theme.orange.opacity(0.8) : (isSelected ? theme.orange.opacity(0.35) : theme.border),
                        lineWidth: focused ? 1.2 : 0.8
                    )
                )
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focused)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Divider

struct LXDivider: View {
    @Environment(\.lxTheme) private var theme
    var body: some View {
        Rectangle().fill(theme.border).frame(height: 1)
    }
}

// MARK: - Progress

struct LXProgressBar: View {
    @Environment(\.lxTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    var height: CGFloat = 5
    var tint: Color?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceHover)
                Capsule()
                    .fill(tint ?? theme.orange)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: fraction)
        .accessibilityValue(Text("\(Int(fraction * 100))%"))
    }
}

// MARK: - Avatar / appearance placeholder

struct LXAvatar: View {
    @Environment(\.lxTheme) private var theme
    let name: String
    var size: CGFloat = 44
    var showsRing: Bool = false
    var skinTextureURL: URL? = nil

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : String(letters.prefix(2)).uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(8, size * 0.28), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.orangeSoft, theme.surfaceRaised],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let skinTextureURL {
                AsyncImage(url: skinTextureURL) { phase in
                    if case let .success(image) = phase {
                        SkinHeadCrop(image: image, size: size)
                    } else {
                        initialsView
                    }
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(8, size * 0.28), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: max(8, size * 0.28), style: .continuous)
                .strokeBorder(showsRing ? theme.orange.opacity(0.45) : theme.border, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var initialsView: some View {
        Text(initials)
            .font(.system(size: max(13, size * 0.32), weight: .bold, design: .rounded))
            .foregroundStyle(theme.orange)
    }
}

private struct SkinHeadCrop: View {
    let image: Image
    let size: CGFloat

    var body: some View {
        let scale = size / 8
        ZStack(alignment: .topLeading) {
            image
                .resizable()
                .interpolation(.none)
                .frame(width: 64 * scale, height: 64 * scale)
                .offset(x: -8 * scale, y: -8 * scale)
            image
                .resizable()
                .interpolation(.none)
                .frame(width: 64 * scale, height: 64 * scale)
                .offset(x: -40 * scale, y: -8 * scale)
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

struct LXSkinSlot: View {
    @Environment(\.lxTheme) private var theme
    let title: String
    let systemImage: String
    let subtitle: String
    var height: CGFloat = 98
    var imageURL: URL? = nil

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .padding(6)
                        case .failure:
                            placeholderIcon
                        default:
                            ProgressView()
                                .controlSize(.mini)
                                .tint(theme.orange)
                        }
                    }
                } else {
                    placeholderIcon
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 58)

            Text(title)
                .font(LXFont.captionStrong)
                .foregroundStyle(theme.textSecondary)
            Text(subtitle)
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: height)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                .fill(theme.canvas.opacity(theme.isDark ? 0.32 : 0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title)：\(subtitle)"))
    }

    private var placeholderIcon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .light))
            .foregroundStyle(theme.orange.opacity(0.7))
    }
}

// MARK: - Empty state / error

struct LXEmptyState: View {
    @Environment(\.lxTheme) private var theme
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: LXSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.orange.opacity(0.75))
                .frame(width: 52, height: 52)
                .background(theme.orangeSoft, in: RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous))
            Text(title)
                .font(LXFont.headline)
                .foregroundStyle(theme.text)
            Text(message)
                .font(LXFont.body)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                LXButton(actionTitle, kind: .secondary, action: action)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(LXSpace.xl)
    }
}

struct LXErrorBanner: View {
    @Environment(\.lxTheme) private var theme
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.danger)
                .padding(.top, 1)
            Text(message)
                .font(LXFont.body)
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            LXIconButton(systemImage: "xmark", label: "关闭错误提示", action: dismiss)
        }
        .padding(.horizontal, LXSpace.md)
        .padding(.vertical, 10)
        .background(theme.danger.opacity(theme.isDark ? 0.12 : 0.08))
        .overlay(alignment: .bottom) { LXDivider() }
    }
}

// MARK: - Inputs

extension View {
    func lxInput() -> some View {
        modifier(LXInputModifier())
    }
}

private struct LXInputModifier: ViewModifier {
    @Environment(\.lxTheme) private var theme
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(LXFont.body)
            .foregroundStyle(theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.canvas.opacity(theme.isDark ? 0.55 : 0.45), in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 0.8)
            )
    }
}

struct LXKeyValue: View {
    @Environment(\.lxTheme) private var theme
    let label: String
    let value: String
    var monospaced: Bool = false
    var valueColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(monospaced ? LXFont.mono : LXFont.bodyStrong)
                .foregroundStyle(valueColor ?? theme.text)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
