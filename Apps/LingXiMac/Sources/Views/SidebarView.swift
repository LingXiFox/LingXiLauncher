import LauncherCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme

    struct NavItem: Identifiable {
        let section: AppModel.Section
        let title: String
        let icon: String
        let badge: String?

        var id: String { section.rawValue }
    }

    private var groups: [(String, [NavItem])] {
        [
            ("PLAY", [NavItem(section: .home, title: "首页", icon: "house.fill", badge: nil)]),
            ("LIBRARY", [
                NavItem(
                    section: .instances,
                    title: "游戏实例",
                    icon: "square.stack.3d.up.fill",
                    badge: model.instances.isEmpty ? nil : "\(model.instances.count)"
                ),
                NavItem(section: .downloads, title: "版本下载", icon: "arrow.down.circle", badge: nil),
            ]),
            ("ACCOUNT", [NavItem(section: .accounts, title: "账户管理", icon: "person.crop.circle", badge: nil)]),
            ("SYSTEM", [
                NavItem(section: .logs, title: "运行日志", icon: "text.alignleft", badge: nil),
                NavItem(section: .settings, title: "设置", icon: "gearshape", badge: nil),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, LXSpace.lg)
                .padding(.top, LXSpace.lg)
                .padding(.bottom, LXSpace.lg)

            LXDivider()
                .padding(.horizontal, LXSpace.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: LXSpace.lg) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            LXOverline(text: group.0)
                                .padding(.horizontal, LXSpace.sm)
                                .padding(.bottom, 1)
                            ForEach(group.1) { item in
                                SidebarNavButton(
                                    item: item,
                                    selected: model.section == item.section
                                ) {
                                    model.section = item.section
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, LXSpace.md)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)

            VStack(spacing: LXSpace.sm) {
                LXDivider()
                accountFooter
                statusFooter
            }
            .padding(.horizontal, LXSpace.md)
            .padding(.bottom, LXSpace.md)
        }
        .background(theme.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 11) {
            LXFoxMark(size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("LINGXI")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(theme.text)
                Text("LAUNCHER")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(3.0)
                    .foregroundStyle(theme.orange)
            }
            Spacer(minLength: 4)
            Text("v\(LauncherInfo.version)")
                .font(LXFont.monoSmall)
                .foregroundStyle(theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("LingXi Launcher \(LauncherInfo.version)")
    }

    private var accountFooter: some View {
        Button {
            model.section = .accounts
        } label: {
            HStack(spacing: 9) {
                LXAvatar(name: model.activeMicrosoftAccount?.playerName ?? "?", size: 30, skinTextureURL: model.playerAppearance?.skinTextureURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.activeMicrosoftAccount?.playerName ?? "未登录")
                        .font(LXFont.bodyStrong)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(model.activeMicrosoftAccount == nil ? "连接 Microsoft 账户" : "Microsoft · 正版")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                    .fill(theme.surface.opacity(theme.isDark ? 0.55 : 0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.activeMicrosoftAccount == nil ? "未登录，打开账户管理" : "当前账户 \(model.activeMicrosoftAccount?.playerName ?? "")，打开账户管理")
    }

    private var statusFooter: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.isGameRunning ? theme.success : theme.textTertiary.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(model.isGameRunning ? "游戏运行中" : "等待启动")
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
            Spacer()
            if let pid = model.gamePID {
                Text("PID \(pid)")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarNavButton: View {
    @Environment(\.lxTheme) private var theme
    @State private var hovering = false
    @FocusState private var focused: Bool

    let item: SidebarView.NavItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? theme.orange : theme.textTertiary)
                Text(item.title)
                    .font(LXFont.bodyStrong)
                    .foregroundStyle(selected ? theme.text : theme.textSecondary)
                Spacer(minLength: 4)
                if let badge = item.badge {
                    Text(badge)
                        .font(LXFont.monoSmall)
                        .foregroundStyle(selected ? theme.orange : theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(selected ? theme.orangeSoft : theme.surfaceRaised)
                        )
                }
                if selected {
                    Capsule()
                        .fill(theme.orange)
                        .frame(width: 2, height: 13)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                    .fill(selected ? theme.sidebarActive : (hovering ? theme.surfaceHover.opacity(0.7) : .clear))
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(theme.orange)
                        .frame(width: 2, height: 16)
                        .padding(.leading, 1)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                    .strokeBorder(focused ? theme.text.opacity(0.28) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct LXFoxMark: View {
    @Environment(\.lxTheme) private var theme
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.orange, theme.orangeStrong],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            FoxGlyph()
                .fill(theme.onOrange.opacity(0.92))
                .padding(size * 0.20)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .strokeBorder(theme.orangeStrong.opacity(0.5), lineWidth: 0.7)
        )
        .shadow(color: theme.orange.opacity(0.18), radius: 10, x: 0, y: 4)
        .accessibilityHidden(true)
    }
}

private struct FoxGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.76))
        path.addLine(to: CGPoint(x: w * 0.27, y: h * 0.57))
        path.addLine(to: CGPoint(x: w * 0.25, y: h * 0.26))
        path.addLine(to: CGPoint(x: w * 0.40, y: h * 0.40))
        path.addLine(to: CGPoint(x: w * 0.50, y: h * 0.35))
        path.addLine(to: CGPoint(x: w * 0.60, y: h * 0.40))
        path.addLine(to: CGPoint(x: w * 0.75, y: h * 0.26))
        path.addLine(to: CGPoint(x: w * 0.73, y: h * 0.57))
        path.closeSubpath()
        return path
    }
}

